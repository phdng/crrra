/*
 * cranehelperd_start — restarts /usr/local/libexec/cranehelperd.
 *
 * Provenance: CraneSB `_cranehelperd_start` (0x14894) executes this path, and
 * its string literal is CONFIRMED_STATIC. The original binary's implementation
 * is not recovered, so this remains an inferred compatibility helper.
 *
 * Use posix_spawn rather than NSTask: NSTask is a macOS API and is not
 * available in the iOS SDK used by Theos.
 */

#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#ifndef CRANE_ROOTHIDE
#define CRANE_ROOTHIDE 0
#endif
#if CRANE_ROOTHIDE
#include <roothide.h>
#endif

extern char **environ;

int main(void)
{
    /* System APIs need the resolved bootstrap executable path on Roothide;
     * argv[0] remains the virtual bootstrap path, as required by its SDK. */
#if CRANE_ROOTHIDE
    const char *launchctl = jbroot("/bin/launchctl");
#else
    const char *launchctl = "/bin/launchctl";
#endif
    char *const argv[] = {
        (char *)"/bin/launchctl",
        (char *)"kickstart",
        (char *)"-k",
        (char *)"system/com.opa334.cranehelperd",
        NULL,
    };

    pid_t pid = 0;
    int error = posix_spawn(&pid, launchctl, NULL, NULL, argv, environ);
    if (error != 0) {
        fprintf(stderr, "cranehelperd_start: posix_spawn: %s\n", strerror(error));
        return 1;
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        fprintf(stderr, "cranehelperd_start: waitpid: %s\n", strerror(errno));
        return 1;
    }

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return 1;
}
