"""Device-report regressions: blank Settings labels and unsafe private calls.

Source/evidence checks are portable. The actual localization fallback also
has a Foundation smoke in CI. None of these claim device crash resolution.
"""
from pathlib import Path
import json
import struct

root = Path(__file__).resolve().parents[1]
common = (root / "sources/common/CRCommon.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRCommon.h").read_text(encoding="utf-8")
localization = (root / "sources/common/CRLocalization.h").read_text(encoding="utf-8")
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
main = (root / "sources/maindylib/CRMainDylib.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

# Roothide uses its SDK resolver for installed files, without moving user data.
assert '#if CRANE_ROOTHIDE' in header
assert '#define CRANE_ROOTHIDE 0' in header
assert '#import <roothide.h>' in header
assert 'return jbroot(path);' in header
assert '[path hasPrefix:@"/var/mobile/"]' in header
assert 'export ADDITIONAL_CFLAGS += -DCRANE_ROOTHIDE=1' in (root / "Makefile").read_text()
assert 'CRLocalizedStringFromBundle(CRUIBundle(), key, &english)' in common
assert 'if (!value || [value isEqualToString:key])' in localization
assert 'if (path.length)' in localization
assert 'return value ?: key;' in localization
assert '!value.length' not in localization  # preserve intentional empty strings
assert 'tools/localization_smoke.m' in workflow

# Object-typed indexForIndexPath makes ARC retain a numeric index as a pointer.
assert '- (NSInteger)indexForIndexPath:(NSIndexPath *)indexPath;' in prefs
assert '- (id)indexForIndexPath:' not in prefs
assert 'NSInteger index = [self indexForIndexPath:indexPath];' in prefs
assert 'index >= 0 && (NSUInteger)index != NSNotFound' in prefs

app = prefs[prefs.index('@implementation CRPApplicationConfigurationListController'):]
detail = prefs[prefs.index('@implementation CRPContainerConfigurationListController'):
               prefs.index('@implementation CRPApplicationListSubcontrollerController')]
listing = prefs[prefs.index('@implementation CRPApplicationListSubcontrollerController'):
                prefs.index('@implementation CRPApplicationConfigurationListController')]
assert listing.index('[rows sortUsingComparator:') < listing.index(
    '[rows insertObject:[PSSpecifier emptyGroupSpecifier] atIndex:0];')
assert app.index('[specifiers addObject:[PSSpecifier emptyGroupSpecifier]];') < app.index(
    '/* Active Container */')
active = app[app.index('- (void)reloadActiveContainer'):app.index('- (void)viewDidLoad')]
assert 'isEqualToString:CRCContainer_ActiveContainer' in active
assert 'firstObject' not in active  # first row is the group, not the active row

for source, method, cache in (
    (app, 'scheduleConfigurationReload', 'craneConfigurationSpecifiers'),
    (detail, 'scheduleContainerConfigurationReload', 'craneContainerSpecifiers'),
):
    start = source.index('- (void)' + method)
    end = source.index('- (void)didChange', start)
    refresh = source[start:end]
    assert 'if (!NSThread.isMainThread)' in refresh
    assert 'if (self.craneReloadScheduled)' in refresh
    assert 'self.craneReloadScheduled = YES;' in refresh
    assert 'self.craneReloadScheduled = NO;' in refresh
    assert 'dispatch_async(dispatch_get_main_queue()' in refresh
    assert f'self.{cache} = nil;' in refresh
    assert '[self reloadSpecifiers];' in refresh
assert 'replaceContiguousSpecifiers:previous withSpecifiers:updated' not in app
for source, start, end in (
    (app, '- (void)addButtonPressed', '@end'),
    (detail, '- (void)makeActiveContainer', '@end'),
):
    action = source[source.index(start):source.index(end, source.index(start))]
    assert '[self reloadSpecifiers];' not in action
    assert '[strongSelf reloadSpecifiers];' not in action

# Every borrowed environment value is read before any unsetenv can invalidate it.
constructor = main[main.index('static void CRInitFunc(void)'):]
first_unset = constructor.index('unsetenv(')
assert constructor.index('initWithUTF8String:identifier') < first_unset
assert constructor.index('strcmp(protect, CR_ENV_PROTECT_VALUE)') < first_unset
assert constructor.index('BOOL spoofLookups = spoof != NULL;') < first_unset
for name in ('CONTAINER_IDENTIFIER', 'PROTECT_CONTAINERS', 'SPOOF_SANDBOX_LOOKUPS'):
    assert constructor.count('unsetenv(CR_ENV_' + name + '.UTF8String)') == 1
assert 'if (buffer && size && home && strlen(home) < size)' in main
assert 'strlcpy(buffer, home, size);' in main
assert 'strncpy(buffer, home, size)' not in main

# Original 0x7360-0x7380 saves x19/x20, checks x2 and tail-branches without
# clobbering the x0/w1 input arguments. Track real bytes, not ignored exports.
fixture = json.loads((root / "tools/fixtures/main_hook_tailcall.json").read_text())
code = bytes.fromhex(fixture["bytes"])
assert int(fixture["start"], 16) == 0x7360
assert int(fixture["tail_branch"], 16) == 0x7380
assert struct.unpack("<9I", code) == (
    0xA9BE4FF4, 0xA9017BFD, 0x910043FD, 0xD503201F,
    0x58009F42, 0xB4000082, 0xA9417BFD, 0xA8C24FF4, 0xD61F0040,
)
assert 'typedef int (*CRLHHookFunctionsFn)(const struct CRHookEntry *table, int count);' in main
assert 'return lhHookFunctions(table, count);' in main
assert 'lhHookFunctions();' not in main
assert 'dlsym(RTLD_DEFAULT, "LHHookFunctions")' in main
print("Crane blank-UI/private-ABI/launch-source regression contracts: PASS (device unverified)")
