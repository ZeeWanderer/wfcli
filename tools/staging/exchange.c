#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s prepared-directory destination\n", argv[0]);
        return 2;
    }
    if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_EXCHANGE) == 0) {
        return 0;
    }
    if (errno == ENOENT &&
        renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_NOREPLACE) == 0) {
        return 0;
    }
    perror("cannot activate staged directory");
    return 1;
}
