#import "TOWXV11Diagnostics.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

static const char *kTOWXV11DiagDir = "/var/mobile/TrollOpenJB";
static const char *kTOWXV11DiagPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

void TOWXV11DiagLog(const char *component, const char *format, ...) {
    (void)mkdir(kTOWXV11DiagDir, 0755);
    int fd = open(kTOWXV11DiagPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char body[1400];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (n < 0) {
        close(fd);
        return;
    }

    struct timeval tv;
    gettimeofday(&tv, NULL);
    long millis = (long)(tv.tv_usec / 1000);

    char line[1800];
    int m = snprintf(line, sizeof(line), "%lld.%03ld TOWX|V11|%s|%s\n",
                     (long long)tv.tv_sec,
                     millis,
                     component ? component : "?",
                     body);
    if (m > 0) {
        size_t length = (size_t)m;
        if (length > sizeof(line)) length = sizeof(line);
        (void)write(fd, line, length);
    }
    close(fd);
}
