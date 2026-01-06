// SPDX-License-Identifier: GPL-2.0
/*
 * Mock Accelerator PCI Driver
 *
 * A simple PCI driver for mock accelerator devices emulated via vfio-user.
 * Exposes device attributes via sysfs for DRA driver discovery.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/device.h>
#include <linux/idr.h>
#include <linux/uuid.h>
#include <linux/version.h>
#include <linux/firmware.h>

#define DRV_NAME "mock-accel"
#define DRV_VERSION "1.0"

/* PCI IDs */
#define MOCK_VENDOR_ID 0x1de5  /* Eideticom, Inc */
#define MOCK_PF_DEVICE_ID 0x0001  /* Physical Function */
#define MOCK_VF_DEVICE_ID 0x0002  /* Virtual Function */

/* BAR0 Register Offsets */
#define REG_DEVICE_ID       0x00
#define REG_REVISION        0x04
#define REG_UUID            0x08
#define REG_MEMORY_SIZE     0x20
#define REG_CAPABILITIES    0x28
#define REG_STATUS          0x2C
#define REG_FW_VERSION      0x30

/* Passphrase Generator Registers */
#define REG_PASSPHRASE_CMD     0x100
#define REG_PASSPHRASE_LENGTH  0x104
#define REG_PASSPHRASE_STATUS  0x108
#define REG_PASSPHRASE_COUNT   0x10C
#define REG_PASSPHRASE_BUFFER  0x200

/* BAR sizes */
#define BAR0_SIZE           4096

/* Device state */
struct mock_accel_dev {
	struct pci_dev *pdev;
	void __iomem *bar0;
	struct device *class_dev;
	int minor;

	/* Cached device attributes */
	uuid_t uuid;
	u64 memory_size;
	u32 capabilities;
	u32 status;
	u32 fw_version;

	/* Firmware management */
	const struct firmware *wordlist_fw;
	bool wordlist_loaded;

	/* SR-IOV support */
	bool is_vf;
	int sriov_total_vfs;
	int sriov_num_vfs;
	struct pci_dev *physfn;  /* Physical function (for VFs) */
};

static struct class *mock_accel_class;
static DEFINE_IDA(mock_accel_ida);

/*
 * Read UUID from BAR0
 */
static void read_uuid(struct mock_accel_dev *mdev)
{
	u32 *uuid_words = (u32 *)&mdev->uuid;
	int i;

	for (i = 0; i < 4; i++) {
		uuid_words[i] = ioread32(mdev->bar0 + REG_UUID + (i * 4));
	}
}

/*
 * Read device attributes from BAR0
 */
static void read_device_attrs(struct mock_accel_dev *mdev)
{
	u32 mem_lo, mem_hi;

	read_uuid(mdev);

	mem_lo = ioread32(mdev->bar0 + REG_MEMORY_SIZE);
	mem_hi = ioread32(mdev->bar0 + REG_MEMORY_SIZE + 4);
	mdev->memory_size = ((u64)mem_hi << 32) | mem_lo;

	mdev->capabilities = ioread32(mdev->bar0 + REG_CAPABILITIES);
	mdev->status = ioread32(mdev->bar0 + REG_STATUS);
	mdev->fw_version = ioread32(mdev->bar0 + REG_FW_VERSION);
}

/*
 * sysfs attribute: uuid
 */
static ssize_t uuid_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	return sprintf(buf, "%pUb\n", &mdev->uuid);
}
static DEVICE_ATTR_RO(uuid);

/*
 * sysfs attribute: memory_size
 */
static ssize_t memory_size_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	return sprintf(buf, "%llu\n", mdev->memory_size);
}
static DEVICE_ATTR_RO(memory_size);

/*
 * sysfs attribute: capabilities
 */
static ssize_t capabilities_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	return sprintf(buf, "0x%08x\n", mdev->capabilities);
}
static DEVICE_ATTR_RO(capabilities);

/*
 * sysfs attribute: status (read/write for allocation state)
 */
static ssize_t status_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	/* Re-read from hardware */
	mdev->status = ioread32(mdev->bar0 + REG_STATUS);

	return sprintf(buf, "0x%08x\n", mdev->status);
}

static ssize_t status_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 val;
	int ret;

	ret = kstrtou32(buf, 0, &val);
	if (ret)
		return ret;

	/* Write to hardware */
	iowrite32(val, mdev->bar0 + REG_STATUS);
	mdev->status = val;

	return count;
}
static DEVICE_ATTR_RW(status);

/*
 * sysfs attribute: numa_node (inherited from PCI device)
 */
static ssize_t numa_node_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	int node = dev_to_node(&mdev->pdev->dev);

	return sprintf(buf, "%d\n", node);
}
static DEVICE_ATTR_RO(numa_node);

/*
 * sysfs attribute: sriov_totalvfs (PF only, read-only)
 */
static ssize_t sriov_totalvfs_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	if (mdev->is_vf)
		return -EINVAL;

	return sprintf(buf, "%d\n", mdev->sriov_total_vfs);
}
static DEVICE_ATTR_RO(sriov_totalvfs);

/*
 * sysfs attribute: sriov_numvfs (PF only, read/write)
 */
static ssize_t sriov_numvfs_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	if (mdev->is_vf)
		return -EINVAL;

	return sprintf(buf, "%d\n", mdev->sriov_num_vfs);
}

static ssize_t sriov_numvfs_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	int ret, num_vfs;

	if (mdev->is_vf)
		return -EINVAL;

	ret = kstrtoint(buf, 0, &num_vfs);
	if (ret)
		return ret;

	if (num_vfs < 0 || num_vfs > mdev->sriov_total_vfs)
		return -EINVAL;

	/* Disable VFs if num_vfs is 0 */
	if (num_vfs == 0 && mdev->sriov_num_vfs > 0) {
		pci_disable_sriov(mdev->pdev);
		mdev->sriov_num_vfs = 0;
		dev_info(dev, "Disabled SR-IOV\n");
		return count;
	}

	/* Enable VFs */
	if (num_vfs > 0) {
		/* Disable existing VFs first if any */
		if (mdev->sriov_num_vfs > 0)
			pci_disable_sriov(mdev->pdev);

		ret = pci_enable_sriov(mdev->pdev, num_vfs);
		if (ret) {
			dev_err(dev, "Failed to enable %d VFs: %d\n", num_vfs, ret);
			mdev->sriov_num_vfs = 0;
			return ret;
		}

		mdev->sriov_num_vfs = num_vfs;
		dev_info(dev, "Enabled %d VFs\n", num_vfs);
	}

	return count;
}
static DEVICE_ATTR_RW(sriov_numvfs);

/*
 * sysfs attribute: passphrase_length (read/write)
 */
static ssize_t passphrase_length_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 length;

	length = ioread32(mdev->bar0 + REG_PASSPHRASE_LENGTH);
	return sprintf(buf, "%u\n", length);
}

static ssize_t passphrase_length_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 length;
	int ret;

	ret = kstrtou32(buf, 0, &length);
	if (ret)
		return ret;

	if (length < 4 || length > 12)
		return -EINVAL;

	iowrite32(length, mdev->bar0 + REG_PASSPHRASE_LENGTH);
	return count;
}
static DEVICE_ATTR_RW(passphrase_length);

/*
 * sysfs attribute: passphrase_generate (write-only)
 */
static ssize_t passphrase_generate_store(struct device *dev,
					 struct device_attribute *attr,
					 const char *buf, size_t count)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 cmd;
	int ret;

	ret = kstrtou32(buf, 0, &cmd);
	if (ret)
		return ret;

	if (cmd == 1) {
		iowrite32(1, mdev->bar0 + REG_PASSPHRASE_CMD);
	}

	return count;
}
static DEVICE_ATTR_WO(passphrase_generate);

/*
 * sysfs attribute: passphrase_status (read-only)
 */
static ssize_t passphrase_status_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 status;
	const char *status_str;

	status = ioread32(mdev->bar0 + REG_PASSPHRASE_STATUS);

	switch (status) {
	case 0: status_str = "idle"; break;
	case 1: status_str = "busy"; break;
	case 2: status_str = "ready"; break;
	case 3: status_str = "error"; break;
	default: status_str = "unknown"; break;
	}

	return sprintf(buf, "%s\n", status_str);
}
static DEVICE_ATTR_RO(passphrase_status);

/*
 * sysfs attribute: passphrase_count (read-only)
 */
static ssize_t passphrase_count_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	u32 count;

	count = ioread32(mdev->bar0 + REG_PASSPHRASE_COUNT);
	return sprintf(buf, "%u\n", count);
}
static DEVICE_ATTR_RO(passphrase_count);

/*
 * sysfs attribute: passphrase (read-only)
 */
static ssize_t passphrase_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	int i;

	/* Read 256 bytes from passphrase buffer */
	for (i = 0; i < 256; i++) {
		buf[i] = ioread8(mdev->bar0 + REG_PASSPHRASE_BUFFER + i);
	}

	/* Ensure null termination */
	buf[255] = '\0';

	/* Find actual string length and add newline */
	i = strlen(buf);
	if (i < 255) {
		buf[i++] = '\n';
		buf[i] = '\0';
	}

	return i;
}
static DEVICE_ATTR_RO(passphrase);

/*
 * sysfs attribute: fw_version (read-only)
 */
static ssize_t fw_version_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	return sprintf(buf, "%u.%u.%u\n",
		       (mdev->fw_version >> 16) & 0xFF,
		       (mdev->fw_version >> 8) & 0xFF,
		       mdev->fw_version & 0xFF);
}
static DEVICE_ATTR_RO(fw_version);

/*
 * sysfs attribute: wordlist_loaded (read-only)
 */
static ssize_t wordlist_loaded_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	return sprintf(buf, "%d\n", mdev->wordlist_loaded ? 1 : 0);
}
static DEVICE_ATTR_RO(wordlist_loaded);

/*
 * sysfs attribute: wordlist_size (read-only)
 */
static ssize_t wordlist_size_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	if (!mdev->wordlist_fw)
		return sprintf(buf, "0\n");

	return sprintf(buf, "%zu\n", mdev->wordlist_fw->size);
}
static DEVICE_ATTR_RO(wordlist_size);

/*
 * sysfs attribute: load_wordlist (write-only, trigger firmware load)
 */
static ssize_t load_wordlist_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);
	int ret;

	/* Release old firmware if loaded */
	if (mdev->wordlist_fw) {
		release_firmware(mdev->wordlist_fw);
		mdev->wordlist_fw = NULL;
		mdev->wordlist_loaded = false;
	}

	/* Request firmware */
	ret = request_firmware(&mdev->wordlist_fw, "mock-accel-wordlist.fw",
			       &mdev->pdev->dev);
	if (ret) {
		dev_err(dev, "Failed to load firmware: %d\n", ret);
		return ret;
	}

	mdev->wordlist_loaded = true;
	dev_info(dev, "Loaded wordlist firmware (%zu bytes)\n",
		 mdev->wordlist_fw->size);

	return count;
}
static DEVICE_ATTR_WO(load_wordlist);

static struct attribute *mock_accel_attrs[] = {
	&dev_attr_uuid.attr,
	&dev_attr_memory_size.attr,
	&dev_attr_capabilities.attr,
	&dev_attr_status.attr,
	&dev_attr_numa_node.attr,
	&dev_attr_fw_version.attr,
	&dev_attr_wordlist_loaded.attr,
	&dev_attr_wordlist_size.attr,
	&dev_attr_load_wordlist.attr,
	&dev_attr_sriov_totalvfs.attr,
	&dev_attr_sriov_numvfs.attr,
	&dev_attr_passphrase_length.attr,
	&dev_attr_passphrase_generate.attr,
	&dev_attr_passphrase_status.attr,
	&dev_attr_passphrase_count.attr,
	&dev_attr_passphrase.attr,
	NULL,
};

static umode_t mock_accel_attr_is_visible(struct kobject *kobj,
					  struct attribute *attr, int n)
{
	struct device *dev = kobj_to_dev(kobj);
	struct mock_accel_dev *mdev = dev_get_drvdata(dev);

	/* SR-IOV attributes only visible for PF */
	if (attr == &dev_attr_sriov_totalvfs.attr ||
	    attr == &dev_attr_sriov_numvfs.attr) {
		if (mdev->is_vf)
			return 0;
	}

	return attr->mode;
}

static const struct attribute_group mock_accel_attr_group = {
	.attrs = mock_accel_attrs,
	.is_visible = mock_accel_attr_is_visible,
};

static const struct attribute_group *mock_accel_groups[] = {
	&mock_accel_attr_group,
	NULL,
};

/*
 * PCI probe - called when device is discovered
 */
static int mock_accel_probe(struct pci_dev *pdev,
			    const struct pci_device_id *id)
{
	struct mock_accel_dev *mdev;
	int ret, minor;

	dev_info(&pdev->dev, "Mock accelerator device found\n");

	mdev = devm_kzalloc(&pdev->dev, sizeof(*mdev), GFP_KERNEL);
	if (!mdev)
		return -ENOMEM;

	mdev->pdev = pdev;
	pci_set_drvdata(pdev, mdev);

	/* Enable PCI device */
	ret = pci_enable_device(pdev);
	if (ret) {
		dev_err(&pdev->dev, "Failed to enable PCI device\n");
		return ret;
	}

	/* Request BAR0 */
	ret = pci_request_region(pdev, 0, DRV_NAME);
	if (ret) {
		dev_err(&pdev->dev, "Failed to request BAR0\n");
		goto err_disable;
	}

	/* Map BAR0 */
	mdev->bar0 = pci_iomap(pdev, 0, BAR0_SIZE);
	if (!mdev->bar0) {
		dev_err(&pdev->dev, "Failed to map BAR0\n");
		ret = -ENOMEM;
		goto err_release;
	}

	/* Read device attributes from registers */
	read_device_attrs(mdev);

	/* Detect SR-IOV support */
	mdev->is_vf = pdev->is_virtfn;
	mdev->sriov_num_vfs = 0;

	if (!mdev->is_vf) {
		/* Physical Function - detect SR-IOV capability */
		int pos = pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_SRIOV);
		if (pos) {
			u16 total_vfs;
			pci_read_config_word(pdev, pos + PCI_SRIOV_TOTAL_VF, &total_vfs);
			mdev->sriov_total_vfs = total_vfs;
			dev_info(&pdev->dev, "SR-IOV capable: %d VFs\n", total_vfs);
		} else {
			mdev->sriov_total_vfs = 0;
		}
		mdev->physfn = NULL;
	} else {
		/* Virtual Function */
		mdev->sriov_total_vfs = 0;
		mdev->physfn = pdev->physfn;
		dev_info(&pdev->dev, "Virtual Function\n");
	}

	dev_info(&pdev->dev, "UUID: %pUb\n", &mdev->uuid);
	dev_info(&pdev->dev, "Memory: %llu bytes\n", mdev->memory_size);
	dev_info(&pdev->dev, "Capabilities: 0x%08x\n", mdev->capabilities);
	dev_info(&pdev->dev, "NUMA node: %d\n", dev_to_node(&pdev->dev));

	/* Allocate minor number */
	minor = ida_simple_get(&mock_accel_ida, 0, 0, GFP_KERNEL);
	if (minor < 0) {
		ret = minor;
		goto err_unmap;
	}
	mdev->minor = minor;

	/* Create device in /sys/class/mock-accel/ */
	if (mdev->is_vf && mdev->physfn) {
		/* VF naming: mock<PF_minor>_vf<VF_index> */
		struct mock_accel_dev *pf_mdev = pci_get_drvdata(mdev->physfn);
		int vf_index = PCI_FUNC(pdev->devfn) - 1;  /* VFs start at function 1 */

		mdev->class_dev = device_create_with_groups(mock_accel_class, &pdev->dev,
							    MKDEV(0, 0), mdev,
							    mock_accel_groups,
							    "mock%d_vf%d",
							    pf_mdev ? pf_mdev->minor : 0,
							    vf_index);
	} else {
		/* PF naming: mock<minor> */
		mdev->class_dev = device_create_with_groups(mock_accel_class, &pdev->dev,
							    MKDEV(0, 0), mdev,
							    mock_accel_groups,
							    "mock%d", minor);
	}
	if (IS_ERR(mdev->class_dev)) {
		ret = PTR_ERR(mdev->class_dev);
		dev_err(&pdev->dev, "Failed to create class device\n");
		goto err_ida;
	}

	/* Load wordlist firmware automatically */
	ret = request_firmware(&mdev->wordlist_fw, "mock-accel-wordlist.fw",
			       &pdev->dev);
	if (ret) {
		dev_warn(&pdev->dev, "Wordlist firmware not found (optional): %d\n", ret);
		mdev->wordlist_loaded = false;
	} else {
		mdev->wordlist_loaded = true;
		dev_info(&pdev->dev, "Loaded wordlist firmware (%zu bytes)\n",
			 mdev->wordlist_fw->size);
	}

	return 0;

err_ida:
	ida_simple_remove(&mock_accel_ida, minor);
err_unmap:
	pci_iounmap(pdev, mdev->bar0);
err_release:
	pci_release_region(pdev, 0);
err_disable:
	pci_disable_device(pdev);
	return ret;
}

/*
 * PCI remove - called when device is removed
 */
static void mock_accel_remove(struct pci_dev *pdev)
{
	struct mock_accel_dev *mdev = pci_get_drvdata(pdev);

	dev_info(&pdev->dev, "Removing mock accelerator device\n");

	/* Release firmware if loaded */
	if (mdev->wordlist_fw) {
		release_firmware(mdev->wordlist_fw);
		mdev->wordlist_fw = NULL;
	}

	/* Disable SR-IOV if this is a PF with VFs enabled */
	if (!mdev->is_vf && mdev->sriov_num_vfs > 0) {
		pci_disable_sriov(pdev);
		dev_info(&pdev->dev, "Disabled SR-IOV (%d VFs)\n", mdev->sriov_num_vfs);
	}

	device_destroy(mock_accel_class, MKDEV(0, mdev->minor));
	ida_simple_remove(&mock_accel_ida, mdev->minor);
	pci_iounmap(pdev, mdev->bar0);
	pci_release_region(pdev, 0);
	pci_disable_device(pdev);
}

static const struct pci_device_id mock_accel_ids[] = {
	{ PCI_DEVICE(MOCK_VENDOR_ID, MOCK_PF_DEVICE_ID) },  /* Physical Function */
	{ PCI_DEVICE(MOCK_VENDOR_ID, MOCK_VF_DEVICE_ID) },  /* Virtual Function */
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, mock_accel_ids);

static struct pci_driver mock_accel_driver = {
	.name = DRV_NAME,
	.id_table = mock_accel_ids,
	.probe = mock_accel_probe,
	.remove = mock_accel_remove,
};

static int __init mock_accel_init(void)
{
	int ret;

	pr_info("Mock Accelerator Driver v%s\n", DRV_VERSION);

	/* Create device class */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
	mock_accel_class = class_create("mock-accel");
#else
	mock_accel_class = class_create(THIS_MODULE, "mock-accel");
#endif
	if (IS_ERR(mock_accel_class)) {
		pr_err("Failed to create device class\n");
		return PTR_ERR(mock_accel_class);
	}

	/* Register PCI driver */
	ret = pci_register_driver(&mock_accel_driver);
	if (ret) {
		pr_err("Failed to register PCI driver\n");
		class_destroy(mock_accel_class);
		return ret;
	}

	return 0;
}

static void __exit mock_accel_exit(void)
{
	pci_unregister_driver(&mock_accel_driver);
	class_destroy(mock_accel_class);
	ida_destroy(&mock_accel_ida);
	pr_info("Mock Accelerator Driver unloaded\n");
}

module_init(mock_accel_init);
module_exit(mock_accel_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Fabien Dupont");
MODULE_DESCRIPTION("Mock Accelerator PCI Driver");
MODULE_VERSION(DRV_VERSION);
