#include "config_worker.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int64_t monotonicMilliseconds(void) {
    struct timespec instant;
    if (clock_gettime(CLOCK_MONOTONIC, &instant) != 0) return -1;
    return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
}

static void closeDescriptor(int *descriptor) {
    if (*descriptor >= 0) close(*descriptor);
    *descriptor = -1;
}

static bool drainPipe(int *descriptor, char *output, size_t capacity, size_t *used, bool truncate) {
    char buffer[4096];
    for (size_t reads = 0; reads < 16; reads++) {
        ssize_t amount = read(*descriptor, buffer, sizeof(buffer));
        if (amount == 0) { closeDescriptor(descriptor); return true; }
        if (amount < 0) {
            if (errno == EINTR) continue;
            return errno == EAGAIN || errno == EWOULDBLOCK;
        }
        size_t available = capacity - *used;
        if ((size_t)amount > available && !truncate) return false;
        size_t copied = (size_t)amount < available ? (size_t)amount : available;
        memcpy(output + *used, buffer, copied);
        *used += copied;
    }
    return true;
}

int config_worker_run(const char *path, char *output, size_t capacity, size_t *used,
                      char *diagnostic, size_t diagnostic_capacity,
                      ConfigCancelled cancelled, void *context) {
    int response[2] = {-1, -1}, errors[2] = {-1, -1};
    int result = 1, status = 0;
    pid_t child = -1;
    bool reaped = false;
    size_t diagnostic_used = 0;
    *used = 0;
    if (diagnostic_capacity) diagnostic[0] = 0;
    int64_t started = monotonicMilliseconds();
    if (started < 0) goto cleanup;
    const int64_t deadline = started + 1000;
    char executable[PATH_MAX];
    uint32_t executable_size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0) goto cleanup;
    if (pipe(response) != 0 || pipe(errors) != 0) goto cleanup;
    for (size_t index = 0; index < 2; index++) {
        // Spawn sources must not overlap the child's fd 0 through 3 targets.
        int *descriptors[] = {&response[index], &errors[index]};
        for (size_t which = 0; which < 2; which++) {
            int replacement = fcntl(*descriptors[which], F_DUPFD_CLOEXEC, 4);
            if (replacement < 0) goto cleanup;
            close(*descriptors[which]);
            *descriptors[which] = replacement;
        }
    }
    if (fcntl(response[0], F_SETFL, O_NONBLOCK) != 0 || fcntl(errors[0], F_SETFL, O_NONBLOCK) != 0) goto cleanup;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions) != 0) goto cleanup;
    if (posix_spawnattr_init(&attributes) != 0) { posix_spawn_file_actions_destroy(&actions); goto cleanup; }
    int spawn_error = posix_spawn_file_actions_adddup2(&actions, response[1], 3);
    if (!spawn_error) spawn_error = posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO);
    if (!spawn_error) spawn_error = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    if (!spawn_error) spawn_error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!spawn_error) spawn_error = posix_spawn_file_actions_addinherit_np(&actions, 3);
    if (!spawn_error) spawn_error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *arguments[] = {executable, "--config-worker", (char *)path, NULL};
    if (!spawn_error) spawn_error = posix_spawn(&child, executable, &actions, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    closeDescriptor(&response[1]);
    closeDescriptor(&errors[1]);
    if (spawn_error) { child = -1; goto cleanup; }
    for (;;) {
        if (cancelled && cancelled(context)) { result = 3; break; }
        int64_t now = monotonicMilliseconds();
        if (now < 0 || now >= deadline) { result = 2; break; }
        if (response[0] >= 0 && !drainPipe(&response[0], output, capacity, used, false)) break;
        if (errors[0] >= 0 && !drainPipe(&errors[0], diagnostic, diagnostic_capacity ? diagnostic_capacity - 1 : 0, &diagnostic_used, true)) break;
        if (!reaped) {
            pid_t waited = waitpid(child, &status, WNOHANG);
            if (waited == child) reaped = true;
            else if (waited < 0 && errno != EINTR) { child = -1; break; }
        }
        if (reaped && response[0] < 0 && errors[0] < 0) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && *used > 0) result = 0;
            break;
        }
        struct pollfd descriptors[] = {{response[0], POLLIN, 0}, {errors[0], POLLIN, 0}};
        int remaining = (int)(deadline - now);
        if (poll(descriptors, 2, remaining < 20 ? remaining : 20) < 0 && errno != EINTR) break;
    }
cleanup:
    closeDescriptor(&response[0]); closeDescriptor(&response[1]);
    closeDescriptor(&errors[0]); closeDescriptor(&errors[1]);
    if (child > 0 && !reaped) {
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    if (diagnostic_capacity) diagnostic[diagnostic_used] = 0;
    return result;
}
