#import "session.h"
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static bool copy_string(CFStringRef string, char *output, size_t capacity) {
    if (!string || CFGetTypeID(string) != CFStringGetTypeID()) return false;
    CFIndex length = CFStringGetLength(string);
    CFIndex used = 0;
    CFIndex converted = CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF8,
                                        0, false, (UInt8 *)output, (CFIndex)capacity - 1, &used);
    if (converted != length || used <= 0 || memchr(output, 0, (size_t)used)) return false;
    output[used] = 0;
    return true;
}

/* Returns 1 when copied, 0 when the attribute is unsupported or has no value, and -1 on failure. */
static int attribute(AXUIElementRef element, CFStringRef name, char *output, size_t capacity) {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(element, name, &value);
    if (result == kAXErrorAttributeUnsupported || result == kAXErrorNoValue) return 0;
    if (result != kAXErrorSuccess || !value) return -1;
    bool valid = copy_string(value, output, capacity);
    CFRelease(value);
    return valid ? 1 : -1;
}

bool huen_session_identify(AXUIElementRef element, pid_t pid, HuenSessionAttributes *output) {
    if (!element || pid <= 0) return false;
    memset(output, 0, sizeof(*output));
    pid_t actual_pid = 0;
    if (AXUIElementGetPid(element, &actual_pid) != kAXErrorSuccess || actual_pid != pid) return false;
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!application || !application.launchDate || !application.bundleIdentifier) return false;
    output->pid = pid;
    output->launch = application.launchDate.timeIntervalSince1970;
    if (!isfinite(output->launch) || output->launch <= 0 ||
        !copy_string((__bridge CFStringRef)application.bundleIdentifier, output->bundle, sizeof(output->bundle)) ||
        attribute(element, kAXRoleAttribute, output->role, sizeof(output->role)) != 1 ||
        attribute(element, kAXSubroleAttribute, output->subrole, sizeof(output->subrole)) < 0) return false;
    int identifier = attribute(element, CFSTR("AXIdentifier"), output->value, sizeof(output->value));
    if (identifier < 0) return false;
    output->kind = identifier ? 1 : 2;
    if (identifier) return true;
    if (attribute(element, kAXDocumentAttribute, output->value, sizeof(output->value)) != 1) return false;
    NSURL *document = [NSURL URLWithString:[NSString stringWithUTF8String:output->value]];
    return document.scheme.length > 0;
}

bool huen_session_display_uuid(CGDirectDisplayID display, char *output, size_t capacity) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return false;
    CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    bool valid = copy_string(string, output, capacity);
    if (string) CFRelease(string);
    CFRelease(uuid);
    return valid;
}

bool huen_session_boot_identity(char *output, size_t capacity) {
    struct timeval boot = {0};
    size_t length = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &length, NULL, 0) != 0 || length != sizeof(boot)) return false;
    int used = snprintf(output, capacity, "%lld.%06d", (long long)boot.tv_sec, boot.tv_usec);
    return used > 0 && (size_t)used < capacity;
}

static bool private_file(int descriptor, mode_t kind, mode_t permissions) {
    struct stat status;
    return fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == kind &&
           status.st_uid == geteuid() && (status.st_mode & 0777) == permissions;
}

static int session_directory(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return -1;
    const char *components[] = {home.fileSystemRepresentation, "Library", "Application Support", "HuenWM"};
    int descriptor = AT_FDCWD;
    for (size_t index = 0; index < 4; index++) {
        bool final = index == 3;
        if (final && mkdirat(descriptor, components[index], 0700) != 0 && errno != EEXIST) {
            close(descriptor);
            return -1;
        }
        int next = openat(descriptor, components[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (descriptor != AT_FDCWD) close(descriptor);
        if (next < 0) return -1;
        struct stat status;
        if (fstat(next, &status) != 0 || status.st_uid != geteuid() ||
            (status.st_mode & 0022) != 0 || (final && !private_file(next, S_IFDIR, 0700))) {
            close(next);
            return -1;
        }
        descriptor = next;
    }
    return descriptor;
}

int huen_session_read(const char *hash, void *output, size_t capacity, size_t *used) {
    char name[96];
    snprintf(name, sizeof(name), "session-%s.json", hash);
    *used = 0;
    int directory = session_directory();
    if (directory < 0) return -1;
    int descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    int open_error = errno;
    close(directory);
    if (descriptor < 0) return open_error == ENOENT ? 1 : -1;
    struct stat status;
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600 || status.st_size <= 0 || (uint64_t)status.st_size > capacity) {
        close(descriptor);
        return -1;
    }
    size_t offset = 0;
    while (offset < capacity) {
        ssize_t count = read(descriptor, (char *)output + offset, capacity - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { close(descriptor); return -1; }
        if (count == 0) break;
        offset += (size_t)count;
    }
    char extra;
    ssize_t trailing;
    do { trailing = read(descriptor, &extra, 1); } while (trailing < 0 && errno == EINTR);
    close(descriptor);
    if (trailing != 0 || offset == 0) return -1;
    *used = offset;
    return 0;
}

bool huen_session_write(const char *hash, const void *bytes, size_t length) {
    char name[96];
    snprintf(name, sizeof(name), "session-%s.json", hash);
    int directory = session_directory();
    if (directory < 0) return false;
    struct stat existing;
    if (fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(existing.st_mode) || existing.st_uid != geteuid() || (existing.st_mode & 0777) != 0600) {
            close(directory);
            return false;
        }
    } else if (errno != ENOENT) {
        close(directory);
        return false;
    }
    char temporary[128];
    snprintf(temporary, sizeof(temporary), ".session-%s-%08x.tmp", hash, arc4random());
    int descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) { close(directory); return false; }
    bool success = private_file(descriptor, S_IFREG, 0600);
    size_t offset = 0;
    while (success && offset < length) {
        ssize_t count = write(descriptor, (const char *)bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = false; break; }
        offset += (size_t)count;
    }
    if (success) success = fsync(descriptor) == 0;
    if (close(descriptor) != 0) success = false;
    if (success) success = renameat(directory, temporary, directory, name) == 0;
    if (success) success = fsync(directory) == 0;
    if (!success) unlinkat(directory, temporary, 0);
    close(directory);
    return success;
}
