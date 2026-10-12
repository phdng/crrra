"""F-09 AccountsDaemon isolated SQLite store attachment contracts.

Evidence: original CraneSupport 0x7CB8 (CF >= 1665.15) builds a
per-container NSPersistentStoreCoordinator and calls
addPersistentStoreWithType:NSSQLiteStoreType, while 0x8324 (legacy) opens
ACDDatabase at <accounts root>/Crane/<container>.sqlite. Native code
does not examine the addPersistentStore result. Reconstruction now
refuses invalid identifiers, symlinked database/sidecars, and failed
store attachment before replacing the active coordinator.

Source/policy regressions only: actual accountsd, file permissions and
Core Data migration behavior require on-device validation.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = (root / "sources/support/CRAccountsd.m").read_text(encoding="utf-8")

def section(start, end):
    i = src.index(start)
    return src[i:src.index(end, i)]

validation = section("static BOOL CraneAccountsdSafeStoreIdentifier(",
                     "/* ------------------------------------------------------------------------- */\n/* Modern (CF")
modern = section("static BOOL CraneAccountsdApplyModernRedirection(",
                 "static id CraneAccountsdModernInit(")
legacy = section("static BOOL CraneAccountsdApplyLegacyRedirection(",
                 "static id CraneAccountsdLegacyInit(")

for required in (
    'identifier.length > 128',
    '[identifier isEqualToString:@"."]',
    '[identifier isEqualToString:@".."]',
    '@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"',
    '[allowed invertedSet]',
    '[identifier rangeOfCharacterFromSet:unsafe].location == NSNotFound',
    'static BOOL CraneAccountsdSafeStoreDirectory(NSString *path)',
    'destinationOfSymbolicLinkAtPath:path error:NULL',
    'CRCreateDirectoryIfNotExists(path);',
    'return directory && ![fm destinationOfSymbolicLinkAtPath:path error:NULL];',
    'static BOOL CraneAccountsdSafeStorePath(NSString *path)',
    '@[@"", @"-wal", @"-shm"]',
    '[path stringByAppendingString:suffix]',
    'destinationOfSymbolicLinkAtPath:candidate error:NULL',
):
    assert required in validation, required

for required in (
    'if (!databaseConnection ||',
    '!CraneAccountsdSafeStoreIdentifier(requested)',
    '!CraneAccountsdSafeStoreIdentifier(current)',
    'coordinator.persistentStores.count == 0',
    '[databaseURL isFileURL]',
    'CraneAccountsdSafeStoreDirectory(candidate.path)',
    'CraneAccountsdSafeStoreDirectory(gModernAccountsBaseURL.path)',
    'CraneAccountsdSafeStorePath(storeURL.path)',
    'NSError *storeError = nil;',
    'NSPersistentStore *opened =',
    'addPersistentStoreWithType:NSSQLiteStoreType',
    'error:&storeError',
    'if (!opened)',
    'return NO; /* Never install an unattached coordinator. */',
    '[databaseConnection\n        setValue:coordinator',
    '[self setCrane_activeContainer:identifier];',
):
    assert required in modern, required

# Critically, a failed database open returns NO before applying a new
# coordinator or setting crane_activeContainer.
assert modern.index('if (!opened)') < modern.index('[databaseConnection\n        setValue:coordinator')
assert modern.index('CraneAccountsdSafeStorePath(storeURL.path)') < modern.index('addPersistentStoreWithType:')
assert modern.index('[databaseConnection\n        setValue:coordinator') < modern.index('[self setCrane_activeContainer:identifier]')
assert 'error:NULL];' not in modern[modern.index('addPersistentStoreWithType:'):modern.index('if (!opened)')]

for required in (
    'CraneAccountsdSafeStoreIdentifier(current)',
    'CraneAccountsdSafeStoreIdentifier(requested)',
    'CraneAccountsdSafeStoreDirectory(gLegacyAccountsBasePath)',
    'CraneAccountsdSafeStorePath(path)',
    '[[databaseClass alloc] initWithPath:path]',
    'if (!redirectedDatabase)',
    '[self setValue:redirectedDatabase forKey:@"_database"];',
    '[self setCrane_activeContainer:identifier];',
):
    assert required in legacy, required

assert legacy.index('CraneAccountsdSafeStoreDirectory(gLegacyAccountsBasePath)') < legacy.index('[self setValue:redirectedDatabase')
assert legacy.index('CraneAccountsdSafeStorePath(path)') < legacy.index('[[databaseClass alloc] initWithPath:path]')
assert legacy.index('if (!redirectedDatabase)\n        return NO;') < legacy.index('[self setValue:redirectedDatabase')

# Independent models for the accepted path-component and sidecar policies.
ALLOWED = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-')
def acceptable(name):
    return (isinstance(name, str) and 0 < len(name) <= 128
            and name not in ('.', '..') and all(ch in ALLOWED for ch in name))

for name in ('DEFAULT', 'C1', 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE', 'com.apple.Music'):
    assert acceptable(name), name
for name in ('', '.', '..', '../escape', 'C1/../x', 'a\\b', 'line\nfeed',
             'é', None, 'Z' * 129):
    assert not acceptable(name), repr(name)

def safe_db(root_kind, sidecar_kinds):
    return root_kind in ('missing', 'directory') and all(
        kind in ('missing', 'file') for kind in sidecar_kinds
    )

assert safe_db('directory', ('file', 'file', 'missing'))
assert safe_db('missing', ('missing', 'missing', 'missing'))
assert not safe_db('symlink', ('missing', 'missing', 'missing'))
assert not safe_db('file', ('missing', 'missing', 'missing'))
assert not safe_db('directory', ('symlink', 'missing', 'missing'))
assert not safe_db('directory', ('file', 'symlink', 'missing'))
assert not safe_db('directory', ('file', 'file', 'directory'))

def attempt_switch(previous, target, attached):
    return (target, True) if attached else (previous, False)

assert attempt_switch('C1', 'C2', True) == ('C2', True)
assert attempt_switch('C1', 'C2', False) == ('C1', False)

print("Crane F-09 accountsd SQLite attachment and path contracts: PASS (device unverified)")
