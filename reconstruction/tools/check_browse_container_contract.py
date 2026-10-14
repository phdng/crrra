"""F-15 read-only Filza browse controller + native associated-path contracts.

Native libcrane 0xE09C/0xE574 enumerates application, App Group and PlugInKit
container roots as type 0/1/2 and returns identifier -> path mappings. Native
CranePrefs 0xE31C groups them as APPLICATION/GROUPS/PLUGINS and only exposes
paths that currently exist. This is a static/source contract, not a device test.
"""
from pathlib import Path
from urllib.parse import quote

root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")

begin = source.index("@interface CRPBrowseContainerListController : PSListController")
end = source.index("/* Initial container detail controller reconstructed", begin)
browse = source[begin:end]
detail_begin = source.index("@implementation CRPContainerConfigurationListController")
detail_end = source.index("/* Minimal APPLICATIONS list", detail_begin)
detail = source[detail_begin:detail_end]

for token in (
    "- (NSString *)applicationIdentifier",
    "- (NSString *)containerIdentifier",
    "- (void)openPathForSpecifier:(PSSpecifier *)specifier",
    "- (PSSpecifier *)specifierForIdentifier:(NSString *)identifier",
    "- (id)specifiers",
    "enumerate:",
    "pathsAssociatedToContainerWithIdentifier:containerID",
    "ofApplicationWithIdentifier:appID",
    "case 0: applicationPaths[identifier] = path;",
    "case 1: groupPaths[identifier] = path;",
    "case 2: pluginPaths[identifier] = path;",
    '@"title": @"APPLICATION"',
    '@"GROUPS"',
    '@"PLUGINS"',
    "localizedCaseInsensitiveCompare:",
    "[fm fileExistsAtPath:path isDirectory:&directory]",
    "[fm destinationOfSymbolicLinkAtPath:path error:NULL]",
    "[row setProperty:path forKey:@\"pathToOpen\"]",
    "[row setButtonAction:@selector(openPathForSpecifier:)]",
    "pathMap.allValues",
    "[paths containsObject:path]",
    "NSCharacterSet.URLPathAllowedCharacterSet",
    '[NSString stringWithFormat:@"filza://view%@/./", encoded]',
    "[application openURL:url options:@{} completionHandler:nil]",
):
    assert token in browse, token

assert browse.index("enumerate:") < browse.index('@"title": @"APPLICATION"')
assert browse.index('@"GROUPS"') < browse.index('@"PLUGINS"')
assert browse.index("[paths containsObject:path]") < browse.index(
    "NSCharacterSet.URLPathAllowedCharacterSet"
)
assert browse.count("[fm destinationOfSymbolicLinkAtPath:path error:NULL]") == 2
assert "removeItemAtPath:" not in browse
assert "createDirectoryAtPath:" not in browse
assert "CR_DATA_DIR" not in browse

for token in (
    '[NSURL URLWithString:@"filza://"]',
    "[UIApplication.sharedApplication canOpenURL:filzaURL]",
    'CRLocalize(@"BROWSE_DATA")',
    "detail:[CRPBrowseContainerListController class] cell:2 edit:0",
    "[browse setDetailControllerClass:[CRPBrowseContainerListController class]]",
    "[browse setProperty:self.applicationIdentifier",
    "[browse setProperty:self.containerIdentifier",
    "[rows addObject:browse]",
):
    assert token in detail, token

for token in (
    "- (void)enumerate:(void (^)(NSInteger type, NSString *identifier,",
    "LSApplicationProxy",
    'NSSelectorFromString(@"dataContainerURL")',
    'NSSelectorFromString(@"groupContainerURLs")',
    'NSSelectorFromString(@"plugInKitPlugins")',
    'NSSelectorFromString(@"pluginIdentifier")',
    "block(0, appID, path, &stop);",
    "block(1, identifier, path, &stop);",
    "block(2, identifier, path, &stop);",
    "- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:",
    "paths[identifier] = path;",
):
    assert token in manager, token

assert "NSDictionary<NSString *, NSString *> *)pathsAssociated" in header
assert "NSArray<NSString *> *)pathsAssociated" not in header

def can_browse(candidate, paths, existing_dir=True, symlink=False, filza=True):
    return bool(candidate) and candidate in paths and existing_dir and not symlink and filza

root_path = (
    "/private/var/mobile/Containers/Data/Application/"
    "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Library/___Crane_Containers/C1"
)
assert can_browse(root_path, [root_path])
assert not can_browse(root_path, [])
assert not can_browse(root_path, [root_path], existing_dir=False)
assert not can_browse(root_path, [root_path], symlink=True)
assert not can_browse(root_path, [root_path], filza=False)

def filza_url(path):
    return "filza://view" + quote(path, safe="/") + "/./"

assert filza_url("/var/mobile/Some Directory") == (
    "filza://view/var/mobile/Some%20Directory/./"
)
assert filza_url("/var/mobile/C1") == "filza://view/var/mobile/C1/./"

print("Crane F-15 Filza native associated-path contracts: PASS (device unverified)")
