"""F-16 container lifecycle safety contracts for reconstructed libcrane.

The original libcrane has no decompile export. These tests intentionally
enforce safe reconstruction policies, NOT claimed parity with native Crane.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
paths = (root / "sources/common/CRPaths.h").read_text(encoding="utf-8")
mcm = (root / "sources/support/CRMCM.m").read_text(encoding="utf-8")

def part(start, end):
    i = manager.index(start)
    return manager[i:manager.index(end, i)]

# Native CRMCM 0xC2BC/0xC8E8 calls the private selector with type 1.
# Preserve the original-path call, then populate the redirected data path
# through the stricter reconstruction manager. Other paths are rejected.
modern = mcm[mcm.index('static id CRMCMRedirectModernContainer('):mcm.index('static id CRMCMFactoryWithUpdate(')]
assert 'NSSelectorFromString(@"_populateContainerDirectory:ofType:")' in mcm
assert '[manager _populateContainerDirectory:path ofType:1]' in mcm
assert 'NSString *dataPath = [[[result containerPath] containerDataURL] path];' in modern
assert 'CRMCMPopulateContainerDirectoryIfAvailable(dataPath);' in modern
assert 'if ([redirectedData isKindOfClass:[NSString class]] &&' in modern
assert '![redirectedData isEqualToString:dataPath]' in modern
assert 'CRMCMPopulateContainerDirectoryIfAvailable(redirectedData);' in modern
assert modern.index('CRMCMPopulateContainerDirectoryIfAvailable(dataPath);') < modern.index('CRMCMPopulateContainerDirectoryIfAvailable(redirectedData);')

# Original path construction returns the entire base for DEFAULT. This
# manager now resolves a scoped application home, not shared CR_DATA_DIR.
assert 'if ([identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])' in paths
assert 'return basePath;' in paths
assert 'CRJailbreakRootPath(CR_DATA_DIR)' in manager  # only as a rejected root

scaffold = (root / "sources/common/CRContainerScaffold.h").read_text(encoding="utf-8")
safety = part('static BOOL CRManagerSafePathComponent(', '@interface CraneManager ()') + scaffold
for expected in [
    '[component isEqualToString:@"."]',
    '[component isEqualToString:@".."]',
    '[component rangeOfCharacterFromSet:invalid]',
    '[containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    'CRContainerPathForContainer(containerID, base)',
    '[path isEqualToString:expected]',
    'CRManagerVerifiedApplicationHome(appID)',
    'CRManagerCreateEmptyContainer(NSString *path, NSError **error)',
    'CRManagerDirectoryComponentIsSafe(NSString *path)',
    'if (!path.length || !CRManagerDirectoryComponentIsSafe(path))',
    'for (NSString *component in [subdir pathComponents])',
    'if (!CRManagerDirectoryComponentIsSafe(next) ||',
    'CRManagerEnsureDirectory(next, NO, error)',
    'destinationOfSymbolicLinkAtPath:path error:NULL',
    'return [fm createDirectoryAtPath:path withIntermediateDirectories:intermediates',
]:
    assert expected in safety, expected

resolver = part('static NSString *CRManagerVerifiedApplicationHome(', 'static BOOL CRManagerSafeManagedPath(')
for fragment in (
    'NSClassFromString(@"LSApplicationProxy")',
    'NSSelectorFromString(@"applicationProxyForIdentifier:")',
    'NSSelectorFromString(@"dataContainerURL")',
    '[proxy respondsToSelector:homeSEL]',
    '((id (*)(id, SEL, id))objc_msgSend)(',
    '((id (*)(id, SEL))objc_msgSend)(',
    '[(NSURL *)candidate isFileURL]',
    'stringByStandardizingPath',
    'stringByResolvingSymlinksInPath',
    'initWithUUIDString:uuidString',
    '@"/private/var/mobile/Containers/Data/Application"',
    '@"/var/mobile/Containers/Data/Application"',
    'fileExistsAtPath:root',
    'isDirectory:&isDirectory',
    'CRManagerAppContainerParentsAreSafe(root)',
    '@catch (NSException *exception)',
):
    assert fragment in resolver, fragment
assert 'return root;' in resolver
assert 'return nil;' in resolver
assert 'CR_CONTAINERS_DIR_COMPONENT     @"Library/___Crane_Containers"' in paths
parents = part('static BOOL CRManagerAppContainerParentsAreSafe(', 'static NSString *CRManagerVerifiedApplicationHome(')
assert 'for (NSString *relative in @[@"Library", CR_CONTAINERS_DIR_COMPONENT])' in parents
assert '[home stringByAppendingPathComponent:relative]' in parents
assert '[fm destinationOfSymbolicLinkAtPath:candidate error:NULL]' in parents
assert '[fm fileExistsAtPath:candidate isDirectory:&isDirectory]' in parents
assert '&&\n            !isDirectory)' in parents
assert 'return NO;' in parents
assert 'for (NSString *relative in @[@"Library", @"___Crane_Containers"])' not in parents
# The real parent path for every container is <apphome>/Library/___Crane_Containers.
# A symlink or file at either level must fail closed before creating anything.
def safe_parents(library_kind, crane_kind):
    return library_kind in (None, "dir") and crane_kind in (None, "dir")

assert safe_parents(None, None)
assert safe_parents("dir", "dir")
assert not safe_parents("symlink", "dir")
assert not safe_parents("dir", "symlink")
assert not safe_parents("file", "dir")
assert not safe_parents("dir", "file")
assert 'self.containerPaths' not in manager

# Fail closed on missing or unexpected LaunchServices URLs: never infer a
# bundle's UUID from its identifier or accept an arbitrary supplied root.
import re

def verified_home(candidate, exists=True, directory=True, symlink=False):
    if not isinstance(candidate, str):
        return None
    path = candidate.rstrip("/")
    match = re.fullmatch(
        r'/(?:private/)?var/mobile/Containers/Data/Application/'
        r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12})', path)
    return path if match and exists and directory and not symlink else None

home = "/private/var/mobile/Containers/Data/Application/4C860E5A-07AF-43EF-A842-58369F6EE20E"
assert verified_home(home) == home
assert verified_home(home.replace("/private", "", 1))
assert verified_home(home, exists=False) is None
assert verified_home(home, directory=False) is None
assert verified_home(home, symlink=True) is None
for invalid_home in (
    None, "", "/var/mobile/Library/Crane",
    "/tmp/Containers/Data/Application/4C860E5A-07AF-43EF-A842-58369F6EE20E",
    "/private/var/mobile/Containers/Data/Application/../escape",
    "/var/mobile/Containers/Data/Application/not-a-uuid",
):
    assert verified_home(invalid_home) is None

# CraneSupport 0xC2BC/0xC8E8 always sends _populateContainerDirectory:ofType:
# with type 1. The original libcrane body is missing; reconstruction only
# populates precisely scoped non-default OS app-data container paths.
population = part('- (void)_populateContainerDirectory:', '- (NSString *)containerDirectoryForContainerWithIdentifier:')
for fragment in (
    'if (type != 1 || ![path isKindOfClass:[NSString class]]',
    '[[path stringByStandardizingPath] isEqualToString:path]',
    'CRManagerSafePathComponent(containerID)',
    '[containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    '[containerID hasPrefix:@".crane-"]',
    'CRContainerPathForContainer(containerID, appHome)',
    '[appHome stringByResolvingSymlinksInPath]',
    'initWithUUIDString:homeUUID',
    '@"/private/var/mobile/Containers/Data/Application"',
    'fileExistsAtPath:appHome isDirectory:&isDirectory',
    'CRManagerAppContainerParentsAreSafe(appHome)',
    'CRManagerDirectoryComponentIsSafe(path)',
    'CRManagerCreateEmptyContainer(path, &error)',
):
    assert fragment in population, fragment
assert population.index('if (type != 1') < population.index('CRManagerCreateEmptyContainer(path, &error)')
assert 'CRJailbreakRootPath(CR_DATA_DIR)' not in population

directory = part('- (NSString *)containerDirectoryForContainerWithIdentifier:',
                 '- (BOOL)cr_containerIdentifierShared:')
assert 'if (!CRManagerSafePathComponent(appID) ||' in directory
assert '!CRManagerSafePathComponent(containerID)' in directory
assert 'NSString *base = CRManagerVerifiedApplicationHome(appID);' in directory
assert 'return base ? CRContainerPathForContainer(containerID, base) : nil;' in directory
assert 'self.containerPaths[key] = path;' not in directory
assert 'NSString *base = CRJailbreakRootPath(CR_DATA_DIR);' not in directory

ownership = part('- (BOOL)cr_containerIdentifierShared:', '- (NSString *)createNewContainerWithName:')
for expected in [
    'CFPreferencesCopyAppValue(',
    'withOtherThan:(NSString *)appID',
    'CFPreferencesCopyKeyList(',
    'kCFPreferencesCurrentUser, kCFPreferencesAnyHost',
    '[key hasPrefix:@"appSettings_"]',
    'CRApplicationSettingsPreferenceKey(otherID)',
    '[otherID isEqual:appID])',
    '[entry[CRCContainer_Identifier] isEqual:identifier]',
    '[[self activeContainerIdentifierForApplicationWithIdentifier:appID]',
    'containsObject:identifier',
    'CRManagerSafeManagedPath(appID, identifier, path)',
    'destinationOfSymbolicLinkAtPath:path error:NULL',
]:
    assert expected in ownership, expected
assert '[self applicationSettingsForApplicationWithIdentifier:otherID]' not in ownership
assert '[self setPreferenceValue:' not in ownership
assert 'if (![settings isKindOfClass:[NSDictionary class]])' in ownership

create = part('- (void)createNewContainerWithName:', '- (void)deleteContentOfContainerWithIdentifier:')
assert 'if (!CRManagerSafePathComponent(appID)' in create
assert '[identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]' in create
assert 'if ([fm destinationOfSymbolicLinkAtPath:path error:NULL])' in create
assert 'BOOL existed = [fm fileExistsAtPath:path];' in create
assert 'if (!registered && existed)' in create
assert 'if (!existed)\n            [fm removeItemAtPath:path error:NULL];' not in create
assert 'NSString *staging = registered ? path :' in create
assert 'if (!CRManagerCreateEmptyContainer(staging, &error))' in create
assert '[fm fileExistsAtPath:staging]' in create
assert '[fm destinationOfSymbolicLinkAtPath:staging error:NULL]' in create
assert create.index('[fm fileExistsAtPath:staging]') < create.index('if (!CRManagerCreateEmptyContainer(staging, &error))')
assert 'if (!registered && ![fm moveItemAtPath:staging toPath:path error:&error])' in create
assert 'if (!registered)\n            [fm removeItemAtPath:staging error:NULL];' in create
assert '[fm removeItemAtPath:staging error:NULL];' in create
# Device-reported repeated Library creation must be idempotent. Check the
# existing real directory before calling the single-level create API.
ensure = scaffold[scaffold.index('static inline BOOL CRManagerEnsureDirectory('):
                  scaffold.index('static inline BOOL CRManagerCreateEmptyContainer(')]
assert ensure.index('fileExistsAtPath:path isDirectory:&isDirectory') < ensure.index('createDirectoryAtPath:path')
assert 'return isDirectory;' in ensure
assert '@"Library/SplashBoard"' in scaffold
assert '#import "CRContainerScaffold.h"' in manager
# Existing registered container scaffolds cannot follow an attacker-added
# Library/Caches or Library/Preferences symlink into another directory.
assert 'NSString *staging = registered ? path :' in create
assert 'CRManagerDirectoryComponentIsSafe(next)' in safety
assert 'CRManagerEnsureDirectory(next, NO, error)' in safety
assert create.index('if (!CRManagerCreateEmptyContainer') < create.index('moveItemAtPath:staging toPath:path') < create.index('[self setContainerSettings:settings')

deletion = part('- (void)deleteContentOfContainerWithIdentifier:', '- (void)wipeContainerWithIdentifier:')
# Original CranePrefs owns the registry mutation. libcrane only clears
# container-associated content and may reload an active target first.
for fragment in (
    'CRManagerSafePathComponent(appID)',
    'CRManagerSafePathComponent(containerID)',
    '[containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    'containsObject:containerID',
    '[self cr_containerIdentifierShared:containerID withOtherThan:appID]',
    '[self reloadApplicationWithIdentifier:appID ifContainerIsActive:containerID]',
    'pathsAssociatedToContainerWithIdentifier:containerID',
    'destinationOfSymbolicLinkAtPath:path error:NULL',
    '[fm removeItemAtPath:path error:&error]',
    'deleteKeychainItemsForContainerWithIdentifier:containerID',
):
    assert fragment in deletion, fragment
assert 'setApplicationSettings:' not in deletion
assert deletion.index('reloadApplicationWithIdentifier:appID') < deletion.index('pathsAssociatedToContainerWithIdentifier:containerID')
wipe = part('- (void)wipeContainerWithIdentifier:', '- (void)makeDefaultForContainerWithIdentifier:')
assert 'if (![self cr_canModifyStoredContainer:containerID' in wipe
assert '[self deleteContentOfContainerWithIdentifier:' not in wipe
assert '[self setContainerSettings:' not in wipe
assert '[self setApplicationSettings:' not in wipe
assert 'if (!repopulate)' in wipe
assert 'CRManagerCreateEmptyContainer(replacement, &error)' in wipe
assert '[fm fileExistsAtPath:replacement]' in wipe
assert '[fm destinationOfSymbolicLinkAtPath:replacement error:NULL]' in wipe
assert '[fm fileExistsAtPath:backup]' in wipe
assert '[fm destinationOfSymbolicLinkAtPath:backup error:NULL]' in wipe
assert wipe.index('[fm fileExistsAtPath:replacement]') < wipe.index('CRManagerCreateEmptyContainer(replacement, &error)')
assert wipe.index('CRManagerCreateEmptyContainer(replacement, &error)') < wipe.index('moveItemAtPath:path toPath:backup')
assert 'moveItemAtPath:replacement toPath:path' in wipe
assert 'moveItemAtPath:backup toPath:path' in wipe
assert wipe.index('moveItemAtPath:replacement toPath:path') < wipe.index('removeItemAtPath:backup error:&error')

unknown = part('- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:', '/* ---- naming')
assert 'NSString *base = CRManagerVerifiedApplicationHome(appID);' in unknown
assert 'if (!base)\n        return @[];' in unknown
assert '[base stringByAppendingPathComponent:' in unknown
assert 'CR_CONTAINERS_DIR_COMPONENT' in unknown
assert 'contentsOfDirectoryAtPath:root error:NULL' in unknown
assert '[registered containsObject:entry]' in unknown
assert '[known containsObject:entry]' in unknown
assert '[entry hasPrefix:@".crane-"]' in unknown
assert '[fm destinationOfSymbolicLinkAtPath:candidate error:NULL]' in unknown
assert '[result sortedArrayUsingSelector:@selector(compare:)]' in unknown
assert 'CRJailbreakRootPath(CR_DATA_DIR)' not in unknown

# Independent input/policy cases; these model the guard, not Objective-C.
def safe_component(value):
    allowed = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-')
    return isinstance(value, str) and bool(value) and value not in ('.', '..') and all(c in allowed for c in value)

def may_mutate(app, cid, active, registered, other_app_owns=False, symlink=False):
    return (safe_component(app) and safe_component(cid) and cid != "DEFAULT"
            and cid in registered and cid != active and not other_app_owns
            and not symlink)

assert safe_component('com.example.app')
assert safe_component('4C860E5A-07AF-43EF-A842-58369F6EE20E')
for value in ['', '.', '..', '../escape', 'other/app', 'evil\\name', '/var/mobile', 'a:b', None]:
    assert not safe_component(value), value
assert may_mutate('com.example.app', 'C1', 'DEFAULT', {'C1'})
assert not may_mutate('com.example.app', 'DEFAULT', 'C1', {'DEFAULT'})
assert not may_mutate('com.example.app', 'C1', 'C1', {'C1'})
assert not may_mutate('com.example.app', 'C2', 'DEFAULT', {'C1'})
assert not may_mutate('com.example.app', 'C1', 'DEFAULT', {'C1'}, other_app_owns=True)
assert not may_mutate('com.example.app', 'C1', 'DEFAULT', {'C1'}, symlink=True)

def modeled_population_path(candidate, container_type=1):
    if not isinstance(candidate, str) or container_type != 1:
        return False
    token = "/Library/___Crane_Containers/"
    if candidate.count(token) != 1:
        return False
    home, identifier = candidate.split(token)
    return (verified_home(home) is not None
            and safe_component(identifier)
            and identifier != "DEFAULT"
            and not identifier.startswith(".crane-"))

assert modeled_population_path(home + "/Library/___Crane_Containers/C1")
for invalid_path in (
    home, home + "/Library/___Crane_Containers/DEFAULT",
    home + "/Library/___Crane_Containers/.crane-old-1",
    home + "/Library/___Crane_Containers/C1/extra",
    home + "/Library/___Crane_Containers/../../other",
    "/var/mobile/Library/Crane/Library/___Crane_Containers/C1",
):
    assert not modeled_population_path(invalid_path), invalid_path
assert not modeled_population_path(home + "/Library/___Crane_Containers/C1", container_type=2)

# The discovery surface may enumerate only within the verified app's own
# Library/___Crane_Containers, and only a safe, directory-like unknown ID.
def modeled_unknown(entries, registered, known):
    eligible = []
    for identifier, is_dir, is_link in entries:
        if (not safe_component(identifier) or identifier == "DEFAULT"
                or identifier.startswith(".crane-")
                or identifier in registered or identifier in known
                or not is_dir or is_link):
            continue
        eligible.append(identifier)
    return sorted(eligible)

assert modeled_unknown([
    ("B", True, False), ("A", True, False), ("DEFAULT", True, False),
    (".crane-old-1", True, False), ("../outside", True, False),
    ("symlink", True, True), ("file.txt", False, False),
    ("registered", True, False), ("known", True, False),
], {"registered"}, {"known"}) == ["A", "B"]

print("Crane F-16 lifecycle safety static contracts: PASS (native build/device unverified)")
