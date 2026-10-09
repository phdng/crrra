/*
 * cranehelperd_start — restarts /usr/local/libexec/cranehelperd.
 *
 * Provenance: CraneSB `_cranehelperd_start` (0x14894) executes this path, and
 * its string literal is CONFIRMED_STATIC. The original binary's behaviour is
 * NOT recovered (no IDA export); the implementation below does the only
 * thing that is observable from the name and from the launchd job: launchctl
 * kickstart the daemon's launchd job.
 *
 * When a notification-support operation needs the daemon and finds it not
 * running, Crane shows CRANEHELPERD_COMMUNICATION_WARNING and offers to fix
 * it. This helper is the "fix" path.
 */

#import <Foundation/Foundation.h>

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/bin/launchctl";
        task.arguments = @[ @"kickstart",
                            @"-k",
                            @"system/com.opa334.cranehelperd" ];
        task.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
        task.standardError = NSFileHandle.fileHandleWithStandardError;

        NSError *error = nil;
        if (![task launchAndReturnError:&error]) {
            fprintf(stderr, "cranehelperd_start: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }
        [task waitUntilExit];
        return task.terminationStatus;
    }
}