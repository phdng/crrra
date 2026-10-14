#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "CRSupportProbeProtocol.h"

static int gRequestToken;

/* A live ping is observable from SpringBoard even when daemon startup
 * messages are absent from mobile's live oslog stream. Positive replies
 * prove injection; missing replies are inconclusive if notify is sandboxed.
 * Never write to user directories or contact the privileged Crane helper. */
__attribute__((constructor))
static void CRSupportProbeFlagsInit(void)
{
    const char *process = getprogname();
    if (!process)
        process = "<unknown>";
    os_log(OS_LOG_DEFAULT,
           "CraneSupportProbe: variant=flags1 constructor process=%{public}s pid=%d",
           process, getpid());

    const char *target = process;
    uint32_t status = notify_register_dispatch(
        CR_SUPPORT_PROBE_PING, &gRequestToken,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int token) {
            (void)token;
            char reply[256];
            int n = snprintf(reply, sizeof(reply), "%s.flags1.%s",
                             CR_SUPPORT_PROBE_REPLY_PREFIX, target);
            if (n > 0 && (size_t)n < sizeof(reply))
                notify_post(reply);
        });
    os_log(OS_LOG_DEFAULT,
           "CraneSupportProbe: variant=flags1 notify_registration process=%{public}s status=%u",
           process, status);
}
