/*
 * Mock Accelerator vfio-user Server
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * This implements a mock PCIe accelerator device using libvfio-user.
 * QEMU connects to this server via a UNIX socket using vfio-user-pci.
 *
 * Usage:
 *   ./mock-accel-server [-v] [-u UUID] [-m MEMORY_SIZE] <socket_path>
 *
 * Example:
 *   ./mock-accel-server -u MOCK-0001 -m 16G /tmp/mock0.sock
 *
 *   qemu-system-x86_64 ... \
 *     -device vfio-user-pci,socket=/tmp/mock0.sock
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <err.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdbool.h>
#include <getopt.h>
#include <sys/random.h>
#include <fcntl.h>

#include "libvfio-user.h"

/* PCI IDs */
#define MOCK_ACCEL_VENDOR_ID    0x1de5
#define MOCK_ACCEL_PF_DEVICE_ID 0x0001  /* Physical Function */
#define MOCK_ACCEL_VF_DEVICE_ID 0x0002  /* Virtual Function */
#define MOCK_ACCEL_SUBSYS_VENDOR_ID 0x0000
#define MOCK_ACCEL_SUBSYS_ID    0x0000

/* BAR0 Register Offsets - Device Info */
#define REG_DEVICE_ID      0x00  /* 4 bytes, RO - "MOCK" magic */
#define REG_REVISION       0x04  /* 4 bytes, RO */
#define REG_UUID           0x08  /* 16 bytes, RO */
#define REG_MEMORY_SIZE    0x20  /* 8 bytes, RO */
#define REG_CAPABILITIES   0x28  /* 4 bytes, RO */
#define REG_STATUS         0x2C  /* 4 bytes, RW */
#define REG_FW_VERSION     0x30  /* 4 bytes, RO - firmware version */

/* BAR0 Register Offsets - Passphrase Generator */
#define REG_PASSPHRASE_CMD     0x100  /* 4 bytes, WO - write 1 to generate */
#define REG_PASSPHRASE_LENGTH  0x104  /* 4 bytes, RW - num words (4-12) */
#define REG_PASSPHRASE_STATUS  0x108  /* 4 bytes, RO - 0=idle, 1=busy, 2=ready, 3=error */
#define REG_PASSPHRASE_COUNT   0x10C  /* 4 bytes, RO - words generated */
#define REG_PASSPHRASE_BUFFER  0x200  /* 256 bytes, RO - passphrase output */

/* BAR0 size */
#define BAR0_SIZE          0x1000  /* 4KB */

/* Magic values */
#define DEVICE_ID_MAGIC    0x4B434F4D  /* "MOCK" in little-endian */
#define REVISION           0x00010000  /* v1.0.0 */
#define FW_VERSION         0x00010000  /* Firmware v1.0.0 */

/* Capability flags */
#define CAP_COMPUTE        (1 << 0)

/* Status flags */
#define STATUS_READY       (1 << 0)

/* Default values */
#define DEFAULT_MEMORY_SIZE (16ULL * 1024 * 1024 * 1024)  /* 16GB */
#define DEFAULT_VF_MEMORY_SIZE (2ULL * 1024 * 1024 * 1024)  /* 2GB */
#define MAX_VFS 7  /* PCIe allows functions 0-7, so max 7 VFs with PF at 0 */

/* SR-IOV Extended Capability */
#define PCI_EXT_CAP_ID_SRIOV  0x10
#define PCI_SRIOV_CAP         0x04  /* SR-IOV Capabilities */
#define PCI_SRIOV_CTRL        0x08  /* SR-IOV Control */
#define PCI_SRIOV_STATUS      0x0a  /* SR-IOV Status */
#define PCI_SRIOV_INITIAL_VF  0x0c  /* InitialVFs */
#define PCI_SRIOV_TOTAL_VF    0x0e  /* TotalVFs */
#define PCI_SRIOV_NUM_VF      0x10  /* NumVFs */
#define PCI_SRIOV_VF_OFFSET   0x14  /* First VF Offset */
#define PCI_SRIOV_VF_STRIDE   0x16  /* VF Stride */
#define PCI_SRIOV_VF_DID      0x1a  /* VF Device ID */

/* Server state */
struct mock_accel_state {
    /* Device properties */
    char uuid[64];
    uint64_t memory_size;
    uint32_t capabilities;

    /* Runtime state */
    uint32_t status;

    /* Parsed UUID bytes */
    uint8_t uuid_bytes[16];

    /* SR-IOV */
    bool is_vf;          /* True if this is a VF, false if PF */
    uint16_t total_vfs;  /* Total VFs supported (PF only) */
    uint16_t vf_index;   /* VF index (0-based, only for VFs) */
    uint8_t sriov_cap[64];  /* SR-IOV capability structure */
    size_t sriov_cap_size;  /* Size of SR-IOV capability */

    /* Passphrase Generator */
    char *wordlist[7776];           /* Loaded EFF wordlist */
    char passphrase_buffer[256];     /* Generated passphrase output */
    uint32_t passphrase_length;      /* Configured word count (4-12) */
    uint32_t passphrase_status;      /* 0=idle, 1=busy, 2=ready, 3=error */
    uint32_t passphrase_count;       /* Actual words in generated passphrase */
};

static volatile bool running = true;

static void signal_handler(int sig)
{
    (void)sig;
    running = false;
}

static void log_fn(vfu_ctx_t *vfu_ctx, int level, char const *msg)
{
    (void)vfu_ctx;
    const char *level_str = "???";
    switch (level) {
    case LOG_ERR:   level_str = "ERR"; break;
    case LOG_INFO:  level_str = "INF"; break;
    case LOG_DEBUG: level_str = "DBG"; break;
    }
    fprintf(stderr, "[%s] %s\n", level_str, msg);
}

static void parse_uuid(struct mock_accel_state *state)
{
    /* Simple UUID parsing - just copy bytes for now */
    size_t len = strlen(state->uuid);
    for (int i = 0; i < 16 && i < (int)len; i++) {
        state->uuid_bytes[i] = state->uuid[i];
    }
}

static int load_wordlist(struct mock_accel_state *state)
{
    FILE *fp = fopen("vfio-user/eff_large_wordlist.txt", "r");
    if (!fp) {
        /* Try alternate path for when running from different directory */
        fp = fopen("eff_large_wordlist.txt", "r");
        if (!fp) {
            fprintf(stderr, "Error: cannot open EFF wordlist file\n");
            return -1;
        }
    }

    char line[128];
    int word_count = 0;

    while (fgets(line, sizeof(line), fp) && word_count < 7776) {
        /* Skip dice roll prefix (5 digits + tab) */
        char *word = strchr(line, '\t');
        if (!word) {
            continue;
        }
        word++;  /* Skip tab character */

        /* Remove newline */
        char *newline = strchr(word, '\n');
        if (newline) {
            *newline = '\0';
        }

        /* Allocate and store word */
        state->wordlist[word_count] = strdup(word);
        if (!state->wordlist[word_count]) {
            fprintf(stderr, "Error: memory allocation failed for wordlist\n");
            fclose(fp);
            return -1;
        }
        word_count++;
    }

    fclose(fp);

    if (word_count != 7776) {
        fprintf(stderr, "Warning: loaded %d words, expected 7776\n", word_count);
    }

    return 0;
}

static void generate_passphrase(vfu_ctx_t *vfu_ctx, struct mock_accel_state *state)
{
    /* Validate word length */
    if (state->passphrase_length < 4 || state->passphrase_length > 12) {
        vfu_log(vfu_ctx, LOG_ERR, "Invalid passphrase length %u (must be 4-12)",
                state->passphrase_length);
        state->passphrase_status = 3;  /* Error */
        return;
    }

    /* Check wordlist is loaded */
    if (!state->wordlist[0]) {
        vfu_log(vfu_ctx, LOG_ERR, "Wordlist not loaded");
        state->passphrase_status = 3;  /* Error */
        return;
    }

    /* Set busy status */
    state->passphrase_status = 1;

    /* Generate random word indices */
    memset(state->passphrase_buffer, 0, sizeof(state->passphrase_buffer));
    char *ptr = state->passphrase_buffer;
    size_t remaining = sizeof(state->passphrase_buffer) - 1;

    for (uint32_t i = 0; i < state->passphrase_length; i++) {
        /* Get cryptographically secure random index */
        uint16_t index;
        ssize_t ret = getrandom(&index, sizeof(index), GRND_NONBLOCK);
        if (ret != sizeof(index)) {
            /* Fall back to /dev/urandom if getrandom fails */
            int fd = open("/dev/urandom", O_RDONLY);
            if (fd < 0 || read(fd, &index, sizeof(index)) != sizeof(index)) {
                vfu_log(vfu_ctx, LOG_ERR, "Failed to get random data");
                state->passphrase_status = 3;  /* Error */
                if (fd >= 0) close(fd);
                return;
            }
            close(fd);
        }

        /* Map to wordlist range (0-7775) */
        index = index % 7776;

        /* Add word to buffer */
        const char *word = state->wordlist[index];
        size_t word_len = strlen(word);

        if (i > 0) {
            /* Add space separator */
            if (remaining < 1) {
                vfu_log(vfu_ctx, LOG_ERR, "Passphrase buffer overflow");
                state->passphrase_status = 3;  /* Error */
                return;
            }
            *ptr++ = ' ';
            remaining--;
        }

        if (remaining < word_len) {
            vfu_log(vfu_ctx, LOG_ERR, "Passphrase buffer overflow");
            state->passphrase_status = 3;  /* Error */
            return;
        }

        memcpy(ptr, word, word_len);
        ptr += word_len;
        remaining -= word_len;
    }

    *ptr = '\0';
    state->passphrase_count = state->passphrase_length;
    state->passphrase_status = 2;  /* Ready */

    vfu_log(vfu_ctx, LOG_DEBUG, "Generated passphrase: %s", state->passphrase_buffer);
}

static ssize_t bar0_access(vfu_ctx_t *vfu_ctx, char * const buf, size_t count,
                            loff_t offset, const bool is_write)
{
    struct mock_accel_state *state = vfu_get_private(vfu_ctx);

    if (is_write) {
        /* Handle writable registers */
        if (offset == REG_STATUS && count == 4) {
            memcpy(&state->status, buf, 4);
            return count;
        }
        if (offset == REG_PASSPHRASE_LENGTH && count == 4) {
            uint32_t length;
            memcpy(&length, buf, 4);
            if (length >= 4 && length <= 12) {
                state->passphrase_length = length;
                return count;
            }
            vfu_log(vfu_ctx, LOG_ERR, "Invalid passphrase length %u (must be 4-12)", length);
            errno = EINVAL;
            return -1;
        }
        if (offset == REG_PASSPHRASE_CMD && count == 4) {
            uint32_t cmd;
            memcpy(&cmd, buf, 4);
            if (cmd == 1) {
                generate_passphrase(vfu_ctx, state);
                return count;
            }
            return count;
        }
        vfu_log(vfu_ctx, LOG_ERR, "write to read-only register 0x%lx", offset);
        errno = EINVAL;
        return -1;
    }

    /* Read operations */
    uint64_t value = 0;
    size_t value_size = 0;

    switch (offset) {
    case REG_DEVICE_ID:
        value = DEVICE_ID_MAGIC;
        value_size = 4;
        break;
    case REG_REVISION:
        value = REVISION;
        value_size = 4;
        break;
    case REG_UUID ... REG_UUID + 15:
        /* Return individual UUID bytes */
        if (count == 1) {
            buf[0] = state->uuid_bytes[offset - REG_UUID];
            return 1;
        }
        /* Multi-byte read of UUID */
        for (size_t i = 0; i < count && (offset - REG_UUID + i) < 16; i++) {
            buf[i] = state->uuid_bytes[offset - REG_UUID + i];
        }
        return count;
    case REG_MEMORY_SIZE:
        value = state->memory_size;
        value_size = 8;
        break;
    case REG_CAPABILITIES:
        value = state->capabilities;
        value_size = 4;
        break;
    case REG_STATUS:
        value = state->status;
        value_size = 4;
        break;
    case REG_FW_VERSION:
        value = FW_VERSION;
        value_size = 4;
        break;
    case REG_PASSPHRASE_LENGTH:
        value = state->passphrase_length;
        value_size = 4;
        break;
    case REG_PASSPHRASE_STATUS:
        value = state->passphrase_status;
        value_size = 4;
        break;
    case REG_PASSPHRASE_COUNT:
        value = state->passphrase_count;
        value_size = 4;
        break;
    case REG_PASSPHRASE_BUFFER ... REG_PASSPHRASE_BUFFER + 255:
        /* Read from passphrase buffer */
        {
            size_t buffer_offset = offset - REG_PASSPHRASE_BUFFER;
            size_t copy_len = count;
            if (buffer_offset + copy_len > sizeof(state->passphrase_buffer)) {
                copy_len = sizeof(state->passphrase_buffer) - buffer_offset;
            }
            memcpy(buf, state->passphrase_buffer + buffer_offset, copy_len);
            return copy_len;
        }
    default:
        vfu_log(vfu_ctx, LOG_DEBUG, "read from unknown register 0x%lx", offset);
        memset(buf, 0, count);
        return count;
    }

    /* Copy value to buffer */
    if (count > value_size) {
        memset(buf, 0, count);
        count = value_size;
    }
    memcpy(buf, &value, count);
    return count;
}

static int device_reset(vfu_ctx_t *vfu_ctx, vfu_reset_type_t type)
{
    struct mock_accel_state *state = vfu_get_private(vfu_ctx);
    (void)type;

    vfu_log(vfu_ctx, LOG_INFO, "device reset");
    state->status = STATUS_READY;

    /* Reset passphrase state */
    state->passphrase_status = 0;
    state->passphrase_count = 0;
    memset(state->passphrase_buffer, 0, sizeof(state->passphrase_buffer));

    return 0;
}

static ssize_t config_space_access(vfu_ctx_t *vfu_ctx, char * const buf,
                                    size_t count, loff_t offset,
                                    const bool is_write)
{
    struct mock_accel_state *state = vfu_get_private(vfu_ctx);
    vfu_pci_config_space_t *config_space = vfu_pci_get_config_space(vfu_ctx);

    vfu_log(vfu_ctx, LOG_DEBUG, "Config space %s: offset=0x%lx count=%zu",
            is_write ? "write" : "read", offset, count);

    /* Handle reads and writes that span multiple regions */
    if (!is_write) {
        /* Read operation */
        size_t bytes_copied = 0;

        /* First, copy standard config space (0x00-0xFF) */
        if (offset < 0x100) {
            size_t std_bytes = (offset + count <= 0x100) ? count : (size_t)(0x100 - offset);
            memcpy(buf, (char *)config_space + offset, std_bytes);
            bytes_copied += std_bytes;
        }

        /* Then, copy extended config space (0x100-0xFFF) */
        if (offset + count > 0x100) {
            size_t ext_start = (offset >= 0x100) ? 0 : (0x100 - offset);
            size_t ext_offset = (offset >= 0x100) ? (offset - 0x100) : 0;
            size_t ext_bytes = count - ext_start;

            /* Copy SR-IOV capability if in range */
            if (ext_offset < state->sriov_cap_size) {
                size_t cap_bytes = (ext_offset + ext_bytes <= state->sriov_cap_size) ?
                                   ext_bytes : (state->sriov_cap_size - ext_offset);
                memcpy(buf + ext_start, state->sriov_cap + ext_offset, cap_bytes);
                vfu_log(vfu_ctx, LOG_DEBUG, "Copied %zu bytes of SR-IOV cap from offset %zu to buf[%zu]",
                        cap_bytes, ext_offset, ext_start);
                /* Dump first 4 bytes of SR-IOV cap for verification */
                if (ext_offset == 0 && cap_bytes >= 4) {
                    uint32_t header = 0;
                    memcpy(&header, buf + ext_start, 4);
                    vfu_log(vfu_ctx, LOG_DEBUG, "SR-IOV header in buffer: 0x%08x", header);
                }
                bytes_copied += cap_bytes;
                ext_start += cap_bytes;
                ext_offset += cap_bytes;
                ext_bytes -= cap_bytes;
            }

            /* Fill remaining extended config space with 0xFF */
            if (ext_bytes > 0) {
                memset(buf + ext_start, 0xff, ext_bytes);
                bytes_copied += ext_bytes;
            }
        }

        vfu_log(vfu_ctx, LOG_DEBUG, "Config space read completed: %zu bytes", bytes_copied);
        return count;
    } else {
        /* Write operation */
        if (offset < 0x100) {
            size_t std_bytes = (offset + count <= 0x100) ? count : (size_t)(0x100 - offset);
            memcpy((char *)config_space + offset, buf, std_bytes);
        }
        /* Ignore writes to extended config space */
        return count;
    }
}

static uint64_t parse_size(const char *str)
{
    char *end;
    uint64_t value = strtoull(str, &end, 10);

    switch (*end) {
    case 'G': case 'g': value *= 1024 * 1024 * 1024; break;
    case 'M': case 'm': value *= 1024 * 1024; break;
    case 'K': case 'k': value *= 1024; break;
    }
    return value;
}

static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s [OPTIONS] <socket_path>\n", prog);
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -v              Verbose logging\n");
    fprintf(stderr, "  -u UUID         Device UUID (default: MOCK-0000-0001)\n");
    fprintf(stderr, "  -m SIZE         Memory size, e.g., 16G (default: 16G for PF, 2G for VF)\n");
    fprintf(stderr, "  --vf            Run as Virtual Function (Device ID 0x0002)\n");
    fprintf(stderr, "  --total-vfs N   Total VFs supported by PF (default: 4, max: %d)\n", MAX_VFS);
    fprintf(stderr, "\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  # Physical Function with 4 VFs\n");
    fprintf(stderr, "  %s -u MOCK-PF-0 -m 16G --total-vfs 4 /tmp/mock-pf-0.sock\n", prog);
    fprintf(stderr, "\n");
    fprintf(stderr, "  # Virtual Function\n");
    fprintf(stderr, "  %s -u MOCK-VF-0 -m 2G --vf /tmp/mock-vf-0-0.sock\n", prog);
    exit(EXIT_FAILURE);
}

int main(int argc, char *argv[])
{
    struct mock_accel_state state = {
        .uuid = "MOCK-0000-0001",
        .memory_size = 0,  /* Will be set based on is_vf */
        .capabilities = CAP_COMPUTE,
        .status = STATUS_READY,
        .is_vf = false,
        .total_vfs = 4,  /* Default: 4 VFs */
        .vf_index = 0,
    };

    bool verbose = false;
    bool memory_size_set = false;
    int opt;
    int option_index = 0;

    static struct option long_options[] = {
        {"vf",        no_argument,       0, 'V'},
        {"vf-index",  required_argument, 0, 'I'},
        {"total-vfs", required_argument, 0, 'T'},
        {"help",      no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    while ((opt = getopt_long(argc, argv, "vu:m:h", long_options, &option_index)) != -1) {
        switch (opt) {
        case 'v':
            verbose = true;
            break;
        case 'u':
            strncpy(state.uuid, optarg, sizeof(state.uuid) - 1);
            break;
        case 'm':
            state.memory_size = parse_size(optarg);
            memory_size_set = true;
            break;
        case 'V':  /* --vf */
            state.is_vf = true;
            break;
        case 'I':  /* --vf-index */
            state.vf_index = (uint16_t)atoi(optarg);
            break;
        case 'T':  /* --total-vfs */
            state.total_vfs = (uint16_t)atoi(optarg);
            if (state.total_vfs > MAX_VFS) {
                fprintf(stderr, "Error: total-vfs cannot exceed %d\n", MAX_VFS);
                exit(EXIT_FAILURE);
            }
            break;
        case 'h':
        default:
            usage(argv[0]);
        }
    }

    /* Set default memory size based on function type if not explicitly set */
    if (!memory_size_set) {
        state.memory_size = state.is_vf ? DEFAULT_VF_MEMORY_SIZE : DEFAULT_MEMORY_SIZE;
    }

    if (optind >= argc) {
        fprintf(stderr, "Error: missing socket path\n\n");
        usage(argv[0]);
    }

    const char *socket_path = argv[optind];

    /* Parse UUID into bytes */
    parse_uuid(&state);

    /* Load EFF wordlist for passphrase generation */
    if (load_wordlist(&state) < 0) {
        fprintf(stderr, "Warning: Failed to load wordlist, passphrase generation disabled\n");
    } else {
        printf("Loaded EFF wordlist (7776 words)\n");
    }

    /* Set up signal handler */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    uint16_t device_id = state.is_vf ? MOCK_ACCEL_VF_DEVICE_ID : MOCK_ACCEL_PF_DEVICE_ID;

    printf("Mock Accelerator Server\n");
    if (state.is_vf) {
        printf("  Type:   Virtual Function (VF %d)\n", state.vf_index);
    } else {
        printf("  Type:   Physical Function\n");
    }
    printf("  Socket: %s\n", socket_path);
    printf("  UUID:   %s\n", state.uuid);
    printf("  Memory: %lu bytes (%.1f GB)\n", state.memory_size,
           (double)state.memory_size / (1024 * 1024 * 1024));
    printf("  PCI ID: %04x:%04x\n", MOCK_ACCEL_VENDOR_ID, device_id);
    if (!state.is_vf && state.total_vfs > 0) {
        printf("  SR-IOV: %d VFs\n", state.total_vfs);
    }
    printf("\n");

    /* Create vfio-user context */
    vfu_ctx_t *vfu_ctx = vfu_create_ctx(VFU_TRANS_SOCK, socket_path, 0,
                                         &state, VFU_DEV_TYPE_PCI);
    if (vfu_ctx == NULL) {
        err(EXIT_FAILURE, "vfu_create_ctx failed");
    }

    /* Set up logging */
    if (vfu_setup_log(vfu_ctx, log_fn, verbose ? LOG_DEBUG : LOG_INFO) < 0) {
        err(EXIT_FAILURE, "vfu_setup_log failed");
    }

    /* Initialize as PCI Express device */
    if (vfu_pci_init(vfu_ctx, VFU_PCI_TYPE_EXPRESS, PCI_HEADER_TYPE_NORMAL, 0) < 0) {
        err(EXIT_FAILURE, "vfu_pci_init failed");
    }

    /* Set PCI IDs */
    vfu_pci_set_id(vfu_ctx, MOCK_ACCEL_VENDOR_ID, device_id,
                   MOCK_ACCEL_SUBSYS_VENDOR_ID, MOCK_ACCEL_SUBSYS_ID);

    /* Set up config space region with extended size for PF only (for SR-IOV capability) */
    if (!state.is_vf) {
        if (vfu_setup_region(vfu_ctx, VFU_PCI_DEV_CFG_REGION_IDX, 4096,
                             &config_space_access, VFU_REGION_FLAG_RW | VFU_REGION_FLAG_ALWAYS_CB,
                             NULL, 0, -1, 0) < 0) {
            err(EXIT_FAILURE, "vfu_setup_region (config space) failed");
        }
    }
    /* VFs use default 256-byte config space */

    /* Build SR-IOV extended capability for PF */
    if (!state.is_vf && state.total_vfs > 0) {
        size_t offset = 0;

        /* Extended Capability Header (4 bytes)
         * Bits 15:0  - Capability ID (0x0010 for SR-IOV)
         * Bits 19:16 - Version (0x1)
         * Bits 31:20 - Next Capability Offset (0x000)
         */
        state.sriov_cap[offset++] = PCI_EXT_CAP_ID_SRIOV;  /* ID low byte: 0x10 */
        state.sriov_cap[offset++] = 0x00;                   /* ID high byte: 0x00 */
        state.sriov_cap[offset++] = 0x01;                   /* Version[3:0]=1 | Next[3:0]=0 */
        state.sriov_cap[offset++] = 0x00;                   /* Next[11:4] = 0x00 */

        /* SR-IOV Capabilities (4 bytes at offset 0x04) */
        state.sriov_cap[offset++] = 0x01;  /* VF Migration Capable */
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;

        /* SR-IOV Control (2 bytes at offset 0x08) - initially 0 (VF disabled) */
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;

        /* SR-IOV Status (2 bytes at offset 0x0a) */
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;

        /* InitialVFs (2 bytes at offset 0x0c) */
        state.sriov_cap[offset++] = state.total_vfs & 0xff;
        state.sriov_cap[offset++] = (state.total_vfs >> 8) & 0xff;

        /* TotalVFs (2 bytes at offset 0x0e) */
        state.sriov_cap[offset++] = state.total_vfs & 0xff;
        state.sriov_cap[offset++] = (state.total_vfs >> 8) & 0xff;

        /* NumVFs (2 bytes at offset 0x10) - initially 0 */
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;

        /* Function Dependency Link (1 byte at offset 0x12) */
        state.sriov_cap[offset++] = 0x00;

        /* Reserved (1 byte at offset 0x13) */
        state.sriov_cap[offset++] = 0x00;

        /* First VF Offset (2 bytes at offset 0x14) - VFs start at function 1 */
        state.sriov_cap[offset++] = 0x01;  /* Offset = 1 */
        state.sriov_cap[offset++] = 0x00;

        /* VF Stride (2 bytes at offset 0x16) - VFs are consecutive */
        state.sriov_cap[offset++] = 0x01;  /* Stride = 1 */
        state.sriov_cap[offset++] = 0x00;

        /* Reserved (2 bytes at offset 0x18) */
        state.sriov_cap[offset++] = 0x00;
        state.sriov_cap[offset++] = 0x00;

        /* VF Device ID (2 bytes at offset 0x1a) */
        state.sriov_cap[offset++] = MOCK_ACCEL_VF_DEVICE_ID & 0xff;
        state.sriov_cap[offset++] = (MOCK_ACCEL_VF_DEVICE_ID >> 8) & 0xff;

        /* Save the capability size */
        state.sriov_cap_size = offset;

        printf("Built SR-IOV capability (%zu bytes, TotalVFs=%d)\n",
               state.sriov_cap_size, state.total_vfs);
        printf("SR-IOV capability will be provided via config space callback\n");
    }

    /* Set up BAR0 region */
    if (vfu_setup_region(vfu_ctx, VFU_PCI_DEV_BAR0_REGION_IDX, BAR0_SIZE,
                         &bar0_access, VFU_REGION_FLAG_RW, NULL, 0, -1, 0) < 0) {
        err(EXIT_FAILURE, "vfu_setup_region failed");
    }

    /* Set up device reset callback */
    if (vfu_setup_device_reset_cb(vfu_ctx, &device_reset) < 0) {
        err(EXIT_FAILURE, "vfu_setup_device_reset_cb failed");
    }

    /* Realize the device */
    if (vfu_realize_ctx(vfu_ctx) < 0) {
        err(EXIT_FAILURE, "vfu_realize_ctx failed");
    }

    printf("Waiting for QEMU to connect...\n");

    /* Attach (wait for client) */
    if (vfu_attach_ctx(vfu_ctx) < 0) {
        err(EXIT_FAILURE, "vfu_attach_ctx failed");
    }

    printf("QEMU connected, serving device...\n");

    /* Main event loop */
    while (running) {
        int ret = vfu_run_ctx(vfu_ctx);
        if (ret < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == ENOTCONN || errno == ESHUTDOWN) {
                printf("Client disconnected\n");
                break;
            }
            err(EXIT_FAILURE, "vfu_run_ctx failed");
        }
    }

    printf("Shutting down...\n");
    vfu_destroy_ctx(vfu_ctx);

    return EXIT_SUCCESS;
}
