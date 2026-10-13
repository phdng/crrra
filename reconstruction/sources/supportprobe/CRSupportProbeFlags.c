#include <os/log.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor))
static void CRSupportProbeFlagsInit(void)
{
    const char *process = getprogname();
    if (!process)
        process = "<unknown>";
    os_log(OS_LOG_DEFAULT,
           "CraneSupportProbe: variant=flags1 constructor process=%{public}s pid=%d",
           process, getpid());
}
