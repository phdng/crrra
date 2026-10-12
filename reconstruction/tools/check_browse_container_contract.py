"""F-15 read-only Filza browse controller contracts.

Native CranePrefs 0x11734, 0xDFD4, 0xE030, 0xE08C, 0xE1E0, 0xE31C
show Browse Data only when Filza handles filza://; a dedicated controller
lists known container paths and opens filza://view + URLPath-encoded path
+ /./. The original manager can enumerate group and plugin paths but the
reconstruction has only verified application paths. Do not infer others.
"""
from pathlib import Path
from urllib.parse import quote

root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")

begin = source.index("@interface CRPBrowseContainerListController : PSListController")
end = source.index("/* Initial container detail controller reconstructed", begin)
browse = source[begin:end]
detail_begin = source.index("@implementation CRPContainerConfigurationListController")
detail_end = source.index("/* Minimal APPLICATIONS list", detail_begin)
detail = source[detail_begin:detail_end]

for token in (
    "- (NSString *)applicationIdentifier",
    '- (NSString *)containerIdentifier',
    '[self specifier] propertyForKey:@"applicationIdentifier"',
    '[self specifier] propertyForKey:@"containerIdentifier"',
    "- (void)openPathForSpecifier:(PSSpecifier *)specifier",
    "- (PSSpecifier *)specifierForIdentifier:(NSString *)identifier",
    '- (id)specifiers',
    '[PSSpecifier emptyGroupSpecifier]',
    'CRLocalize(@"APPLICATION")',
    '[row setProperty:path forKey:@"pathToOpen"]',
    '[row setButtonAction:@selector(openPathForSpecifier:)]',
    '[self setValue:self.craneBrowseSpecifiers forKey:@"_specifiers"]',
    'pathsAssociatedToContainerWithIdentifier:containerID',
    'ofApplicationWithIdentifier:appID',
    '[seen containsObject:path]',
    '[fm fileExistsAtPath:path isDirectory:&directory]',
    '[fm destinationOfSymbolicLinkAtPath:path error:NULL]',
    '[paths containsObject:path]',
    'NSCharacterSet.URLPathAllowedCharacterSet',
    '[NSString stringWithFormat:@"filza://view%@/./", encoded]',
    '[application openURL:url options:@{} completionHandler:nil]',
):
    assert token in browse, token

assert browse.count("pathsAssociatedToContainerWithIdentifier:containerID") == 2,     "Recheck verified path at presentation and immediately before opening"
assert browse.count("[fm destinationOfSymbolicLinkAtPath:path error:NULL]") == 2
assert browse.index("[paths containsObject:path]") < browse.index("NSCharacterSet.URLPathAllowedCharacterSet")
assert browse.index("[application canOpenURL:url]") < browse.index("[application openURL:url")
assert "NSFileManager" in browse
assert "removeItemAtPath:" not in browse
assert "createDirectoryAtPath:" not in browse
assert "CR_DATA_DIR" not in browse
assert "Library/___Crane_Containers" not in browse
assert "GROUPS" not in browse and "PLUGINS" not in browse

for token in (
    '[NSURL URLWithString:@"filza://"]',
    '[UIApplication.sharedApplication canOpenURL:filzaURL]',
    'CRLocalize(@"BROWSE_DATA")',
    'detail:[CRPBrowseContainerListController class] cell:2 edit:0',
    '[browse setDetailControllerClass:[CRPBrowseContainerListController class]]',
    '[browse setProperty:self.applicationIdentifier',
    '[browse setProperty:self.containerIdentifier',
    '[rows addObject:browse]',
):
    assert token in detail, token

assert detail.index('if (filzaURL &&') < detail.index('[rows addObject:browse]')
assert "return root ? @[root] : @[];" in manager,     "Scoped manager paths must remain the only browse source"

# An independent model: the path must be in the manager's current list,
# exist as a directory, and be neither symlinked nor stale.
def can_browse(candidate, paths, existing_dir=True, symlink=False, filza=True):
    return bool(candidate) and candidate in paths and existing_dir and            not symlink and filza

root_path = "/private/var/mobile/Containers/Data/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Library/___Crane_Containers/C1"
assert can_browse(root_path, [root_path])
assert not can_browse(root_path, [])
assert not can_browse(root_path, [root_path], existing_dir=False)
assert not can_browse(root_path, [root_path], symlink=True)
assert not can_browse(root_path, [root_path], filza=False)

def filza_url(path):
    # Python's standard quote with '/' safe matches NSCharacterSet.URLPathAllowedCharacterSet
    # for the ASCII slash/spaces exercised here.
    return "filza://view" + quote(path, safe="/") + "/./"

assert filza_url("/var/mobile/Some Directory") ==        "filza://view/var/mobile/Some%20Directory/./"
assert filza_url("/var/mobile/C1") == "filza://view/var/mobile/C1/./"

print("Crane F-15 Filza browse source and safety contracts: PASS (device unverified)")
