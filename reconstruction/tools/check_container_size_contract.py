"""F-15 read-only container size UI and F-16 safe asynchronous accounting.

Native CranePrefs 0x113A4, 0x1148C, 0x11520:
- asks CraneManager for the container size with a callback;
- forwards completion to the main queue;
- formats the byte count and refreshes only the size group footer.

The original libcrane scanner is unavailable. The adapted enumerator refuses
unverified per-app roots and skips symlinks. This is a source/model test, not
a replacement for device storage and native ABI validation.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")

def extract(src, start, end):
    a = src.index(start)
    return src[a:src.index(end, a)]

panel = extract(prefs,
                "@implementation CRPContainerConfigurationListController",
                "/* Minimal APPLICATIONS list for")
size = extract(panel,
               "- (void)updateSizeGroupSpecifierAndReload:(BOOL)reload",
               "/* ChoicyPrefs is optional;")
mgr = extract(manager,
              "- (void)sizeOccupiedByContainerWithIdentifier:",
              "- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:")

assert '#import <limits.h>' in prefs
assert '#import <limits.h>' in manager
for token in (
    "@property (nonatomic, strong) PSSpecifier *sizeGroupSpecifier;",
    "@property (nonatomic, assign) unsigned long long cachedSize;",
    "@property (nonatomic, assign) BOOL sizeCached;",
    "@property (nonatomic, assign) NSUInteger sizeFetchGeneration;",
    "[PSSpecifier emptyGroupSpecifier]",
    "self.sizeGroupSpecifier = sizeGroup;",
    "[rows addObject:sizeGroup];",
    "[self updateSizeGroupSpecifierAndReload:NO];",
    "BOOL shouldUpdateSize = !self.craneContainerSpecifiers;",
    "if (shouldUpdateSize)",
    "[self updateContainerSize];",
    "BOOL alreadyLoaded = self.craneContainerSpecifiers != nil;",
    "if (alreadyLoaded)",
):
    assert token in prefs, token

for token in (
    'CRLocalize(@"SIZE_OF_CONTAINER")',
    '[NSByteCountFormatter stringFromByteCount:count countStyle:0]',
    'self.sizeCached',
    'self.cachedSize > LLONG_MAX',
    '@"(...)"',
    '@"footerText"',
    '[self reloadSpecifier:group];',
    'pathsAssociatedToContainerWithIdentifier:containerID',
    'NSUInteger generation = ++self.sizeFetchGeneration;',
    '__weak typeof(self) weakSelf = self;',
    'sizeOccupiedByContainerWithIdentifier:containerID',
    'dispatch_async(dispatch_get_main_queue(), ^{',
    'generation != strongSelf.sizeFetchGeneration',
    '![appID isEqualToString:strongSelf.applicationIdentifier]',
    '![containerID isEqualToString:strongSelf.containerIdentifier]',
    'strongSelf.cachedSize = bytes;',
    'strongSelf.sizeCached = YES;',
):
    assert token in size, token

assert size.index("sizeOccupiedByContainerWithIdentifier:containerID") < size.index("strongSelf.cachedSize = bytes;")
assert "[manager containerDirectoryForContainerWithIdentifier:" not in size
assert panel.count("self.sizeFetchGeneration++;") >= 2  # changed model or settings
assert "self.sizeCached = NO;" in panel

for token in (
    'CRManagerVerifiedApplicationHome(appID)',
    'CRManagerSafeManagedPath(appID, containerID, root)',
    'if (!valid) {',
    'dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{',
    'if ([fm fileExistsAtPath:root isDirectory:&isDirectory] &&',
    '![fm destinationOfSymbolicLinkAtPath:root error:NULL]',
    '[fm enumeratorAtPath:root]',
    'attrs[NSFileType]',
    'NSFileTypeSymbolicLink',
    '[enumerator skipDescendants];',
    'NSFileTypeRegular',
    'ULLONG_MAX - total < bytes ? ULLONG_MAX : total + bytes',
    'dispatch_async(dispatch_get_main_queue(), ^{ handler(total); });',
):
    assert token in mgr, token

assert mgr.index("if (!valid) {") < mgr.index("dispatch_async(dispatch_get_global_queue")
assert mgr.index("NSFileTypeSymbolicLink") < mgr.index("NSFileTypeRegular")
assert "handler(total);" not in mgr[:mgr.index("dispatch_async(dispatch_get_global_queue")]

# Independent models of the non-atomic accounting and UI-generation gates.
MAX_UINT64 = (1 << 64) - 1
def file_size(items):
    result = 0
    for category, amount in items:
        if category == "regular":
            result = min(MAX_UINT64, result + amount)
    return result

def accept_size(original_generation, current_generation, app_before,
                app_now, container_before, container_now):
    return (original_generation == current_generation and
            app_before == app_now and container_before == container_now)

assert file_size([("directory", 999), ("regular", 40),
                  ("symlink", 1000), ("regular", 2)]) == 42
assert file_size([("regular", MAX_UINT64), ("regular", 9)]) == MAX_UINT64
assert accept_size(3, 3, "app", "app", "C1", "C1")
assert not accept_size(3, 4, "app", "app", "C1", "C1")
assert not accept_size(3, 3, "app", "app2", "C1", "C1")
assert not accept_size(3, 3, "app", "app", "C1", "C2")
print("Crane F-15 container size async footer contracts: PASS (device unverified)")
