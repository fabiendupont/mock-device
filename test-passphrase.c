// test-passphrase.c
// Test program for mock-accel passphrase generation ioctl
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define MOCK_ACCEL_IOC_MAGIC 'M'

struct mock_accel_passphrase {
    uint8_t word_count;
    char passphrase[256];
};

#define MOCK_ACCEL_IOC_STATUS _IOR(MOCK_ACCEL_IOC_MAGIC, 1, uint32_t)
#define MOCK_ACCEL_IOC_PASSPHRASE _IOWR(MOCK_ACCEL_IOC_MAGIC, 2, struct mock_accel_passphrase)

int main(int argc, char **argv) {
    int fd;
    struct mock_accel_passphrase pass;
    uint32_t status;

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <device> [word_count]\n", argv[0]);
        fprintf(stderr, "  word_count: 1-12 words (default: 6 if omitted)\n");
        return 1;
    }

    fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    // Test STATUS ioctl
    if (ioctl(fd, MOCK_ACCEL_IOC_STATUS, &status) < 0) {
        perror("ioctl(STATUS)");
    } else {
        printf("Device status: 0x%08x\n", status);
    }

    // Test PASSPHRASE ioctl
    memset(&pass, 0, sizeof(pass));
    pass.word_count = (argc > 2) ? atoi(argv[2]) : 0;  // 0 = default (6)

    if (ioctl(fd, MOCK_ACCEL_IOC_PASSPHRASE, &pass) < 0) {
        perror("ioctl(PASSPHRASE)");
        close(fd);
        return 1;
    }

    printf("Generated passphrase (%d words): %s\n",
           pass.word_count ? pass.word_count : 6,
           pass.passphrase);

    close(fd);
    return 0;
}
