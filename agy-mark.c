#include <fcntl.h>
#include <unistd.h>

int main(void) {
    int fd = open("/mnt/bounded/agy-used", O_WRONLY | O_CREAT, 0444);
    if (fd >= 0) close(fd);
    return 0;
}
