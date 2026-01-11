# Mock Accelerator Firmware

This directory contains firmware files for the mock-accel kernel driver.

## Wordlist Firmware

The mock-accel driver uses the **EFF Long Wordlist** (7,776 words) for cryptographic passphrase generation.

### Download the Wordlist

```bash
cd firmware
./download-wordlist.sh
```

This script:
1. Downloads the EFF long wordlist from https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
2. Extracts the word column (removing dice roll numbers)
3. Verifies 7,776 words were downloaded
4. Creates `mock-accel-wordlist.txt` in this directory

**Note**: The wordlist file (62KB) is not committed to git. Run the download script to generate it locally.

### Manual Download

If the download script fails, you can manually download and extract the wordlist:

```bash
curl -L -o eff_large_wordlist.txt https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
awk '{print $2}' eff_large_wordlist.txt > mock-accel-wordlist.txt
wc -l mock-accel-wordlist.txt
# Should output: 7776
```

## Firmware Loading Modes

The mock-accel driver loads firmware differently depending on how it's deployed:

### 1. Manual Kernel Module Loading

When loading the module manually (outside Kubernetes):

```bash
# Copy firmware to system firmware directory
sudo cp firmware/mock-accel-wordlist.txt /lib/firmware/

# Load module
sudo insmod kernel-driver/mock-accel.ko

# Verify firmware loaded
sudo dmesg | tail -20
# Expected: "mock-accel 0000:XX:00.0: Loaded 7776 words from firmware"
```

The Linux kernel's firmware loader (`request_firmware()`) searches `/lib/firmware/` for the file.

### 2. Kubernetes (KMM - Kernel Module Management)

When deploying via KMM, firmware is **embedded in the container image**:

**Build Process:**
```dockerfile
# Containerfile
COPY charts/mock-device/firmware/mock-accel-wordlist.txt /lib/firmware/
```

**Helm Chart:**
The wordlist is packaged with the Helm chart at:
```
charts/mock-device/firmware/mock-accel-wordlist.txt
```

When the KMM worker pod starts:
1. Container image includes firmware in `/lib/firmware/`
2. KMM mounts this directory to the host
3. Kernel module loads firmware from the mounted path
4. No manual firmware installation required

**Verify firmware in container:**
```bash
# Check firmware is in the built image
podman run --rm ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc43 \
  ls -lh /lib/firmware/mock-accel-wordlist.txt
# -rw-r--r--. 1 root root 61K ... /lib/firmware/mock-accel-wordlist.txt
```

## Helm Chart Integration

The Helm chart includes a ConfigMap template for firmware documentation:

```yaml
# charts/mock-device/templates/configmap-firmware.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mock-accel-firmware
binaryData:
  mock-accel-wordlist.txt: |-
{{ .Files.Get "firmware/mock-accel-wordlist.txt" | b64enc | indent 4 }}
```

This ConfigMap:
- Documents the firmware content
- Is NOT mounted by KMM (firmware comes from container image)
- Can be used for reference or custom deployment scenarios

## Firmware File Format

The `mock-accel-wordlist.txt` file is a plain text file with one word per line:

```
aardvark
abacus
abbey
abbreviate
abdomen
...
zoom
```

**Specifications:**
- Total words: 7,776 (6^5, matching 5 dice rolls)
- File size: ~62 KB
- Encoding: ASCII/UTF-8
- Format: One word per line, no extra whitespace
- Source: [EFF Long Wordlist](https://www.eff.org/dice)

## Security Considerations

**Entropy:**
- Each word represents log₂(7776) ≈ 12.925 bits of entropy
- 6-word passphrase: 77.5 bits of entropy
- 12-word passphrase: 155 bits of entropy

**Random Number Generation:**
The driver uses `get_random_bytes()` from the Linux kernel, which provides cryptographically secure random numbers suitable for passphrase generation.

**Wordlist Integrity:**
The download script verifies the word count (7,776). For production use, consider adding checksum verification:

```bash
# Example with SHA256 verification (update hash after EFF updates)
EXPECTED_SHA256="<hash-of-original-eff-wordlist>"
echo "$EXPECTED_SHA256  eff_large_wordlist.txt" | sha256sum -c
```

## Troubleshooting

**Firmware loading failed (-2):**
```
mock-accel 0000:11:00.0: Failed to load wordlist firmware: -2
```

This error (ENOENT) means the firmware file was not found. Solutions:

1. **Manual loading**: Copy firmware to `/lib/firmware/`
2. **KMM deployment**: Verify firmware is in container image
3. **Check dmesg**: `dmesg | grep firmware` for detailed error messages

**Passphrase generation disabled:**
If firmware loading fails, the device still works but passphrase generation is disabled:

```bash
cat /dev/mock0
# Wordlist: 0 words loaded
# Sample Passphrase (6 words): (firmware not loaded)
```

The driver continues to function for other operations (sysfs, status register, etc.).

## References

- [EFF Dice-Generated Passphrases](https://www.eff.org/dice)
- [Linux Kernel Firmware API](https://www.kernel.org/doc/html/latest/driver-api/firmware/index.html)
- [KMM Firmware Management](https://github.com/kubernetes-sigs/kernel-module-management)
