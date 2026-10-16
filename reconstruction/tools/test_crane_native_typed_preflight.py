"""G-11 N7 original CraneManager typed enumeration provenance/contract tests.

Mac Foundation smoke executes production Objective-C source with a mock
three-type resolver; no iPhone or user application data is involved.
"""
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "reconstruction/sources/prefs"
TOOLS = REPO / "reconstruction/tools"


class TypedPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (SRC / "CRBackupNativeTypedPreflight.h").read_text(encoding="utf8")
        cls.code = (SRC / "CRBackupNativeTypedPreflight.m").read_text(encoding="utf8")
        cls.manager = (REPO / "reconstruction/sources/libcrane/CRManager.m").read_text(encoding="utf8")
        cls.manager_header = (REPO / "reconstruction/sources/common/CRManager.h").read_text(encoding="utf8")
        cls.smoke = (TOOLS / "native_backup_typed_preflight_smoke.m").read_text(encoding="utf8")
        cls.n6 = (SRC / "CRBackupNativeManagerPreflight.m").read_text(encoding="utf8")

    def test_recovered_original_typed_api_from_manager(self):
        for term in (
            "enumerate:(void (^)(NSInteger type, NSString *identifier,",
            "pathsAssociatedToContainerWithIdentifier:",
            "ofApplicationWithIdentifier:",
        ):
            self.assertIn(term, self.manager_header)
            self.assertIn(term, self.header)
        self.assertIn("block(0, appID, path, &stop)", self.manager)
        self.assertIn("block(1, identifier, path, &stop)", self.manager)
        self.assertIn("block(2, identifier, path, &stop)", self.manager)

    def test_n7_reuses_n5_root_directory_validation(self):
        self.assertIn("CRBackupNativeSourcePreflight", self.code)
        self.assertIn("preflightApplicationIdentifier:applicationID", self.code)
        self.assertIn('n5[@"rootCount"]', self.code)
        self.assertIn('n5[@"sourceDirectoryRootsReadable"]', self.code)

    def test_two_snapshot_consistency_not_one_enumeration(self):
        self.assertIn("CR7TypedSnapshot(resolver, applicationID", self.code)
        self.assertIn("![first isEqualToDictionary:second]", self.code)
        self.assertIn("BOOL firstValid = NO, secondValid = NO", self.code)
        self.assertIn("mapping.count != first.count", self.code)
        self.assertIn('[path isEqualToString:entry[@"path"]]', self.code)

    def test_fail_closed_on_type_duplicate_and_app_identity(self):
        for term in (
            "type == 0 || type == 1 || type == 2",
            "[rows objectForKey:identifier]",
            "rows.count >= CR7MaxRoots",
            "appRoots == 1",
            '[identifier isEqualToString:appID]',
            "[n5[@\"associatedGroupCount\"] unsignedIntegerValue]",
        ):
            self.assertIn(term, self.code)

    def test_no_names_paths_or_keys_exported_in_report(self):
        for marker in (
            '@"applicationRootCount":@(appRoots)',
            '@"appGroupRootCount":@(groups)',
            '@"plugInKitRootCount":@(plugins)',
            '@"sourceFilesEnumerated":@NO',
            '@"sourceContentsRead":@NO',
            '@"keychainContentsRead":@NO',
            '@"backupReady":@NO',
            '@"restoreExecutable":@NO',
        ):
            self.assertIn(marker, self.code)
        self.assertNotIn('@"paths":', self.code)
        self.assertNotIn('@"identifiers":', self.code)
        self.assertNotIn("NSLog(", self.code)

    def test_original_runtime_adapter_provides_explicit_typed_entrypoint(self):
        self.assertIn("probeTypedRegisteredApplication:", self.n6)
        self.assertIn("resolver:(id<CRBackupTypedSourceResolver>)manager", self.n6)
        self.assertIn('NSClassFromString(@"CraneManager")', self.n6)
        self.assertNotIn("probeTypedRegisteredApplication:",
                         (SRC / "CRPreferences.m").read_text(encoding="utf8"))

    def test_mac_fixture_checks_all_types_and_broken_maps(self):
        for marker in (
            '@"type":@0', '@"type":@1', '@"type":@2',
            "resolver.mode = 1", "resolver.mode = 2",
            "resolver.mode = 3", "resolver.mode = 4",
            "resolver.mode = 5", "resolver.mode = 6",
            "Reject(resolver, 3)", "Reject(resolver, 5)",
            "Reject(resolver, 6)", "Reject(resolver, 2)",
        ):
            self.assertIn(marker, self.smoke)

    def test_static_no_data_read_or_mutation(self):
        for prohibited in (
            "readdir(", "open(", "fstatat(", "read(",
            "write(", "SecItem", "KeychainItems", "removeItemAtPath:",
            "setActiveContainer", "createNewContainer", "NSLog(",
        ):
            self.assertNotIn(prohibited, self.code)


if __name__ == "__main__":
    unittest.main()
