"""F-12 PlugInKit per-thread match scope + one-shot result tagging.

Native CraneSupport 0xFD70 -> 0xF174 uses a process-global string, which
can mis-tag plugins if two independent transactions overlap. The adapted
code restricts the string to the calling thread and dynamic matchPlugIns
scope, strips Crane-only private rules, restores nested outer contexts and
clears unconsumed IDs even on exceptional exit. If the original dispatches
a database query to a different thread, the result is left untagged; this
cannot establish true transaction identity without original linkage.

Source checks and independent interleaving model only. No device or native
ObjC compiler verification is implied.
"""
from pathlib import Path
from threading import local

root = Path(__file__).resolve().parents[1]
src = (root / "sources/support/CRPkd.m").read_text(encoding="utf-8")
a = src.index("static NSString *CRPkdVerifiedContainerID(")
b = src.index("typedef NSArray *(^CRPkdFindPlugInsContinuation)", a)
block = src[a:b]
match = block[block.index("static void CRPkdMatchPlugIns("):]
find = src[src.index("static NSArray *CRPkdFindPlugIns("):
           src.index("static id CRPkdFindPlugIns1(")]

assert "static NSString * const kCRPkdScopedContainerIDKey" in src
assert "static NSString *gCRPkdContainerID;" not in src
for needle in (
    'if (!value)', '[NSString stringWithUTF8String:value]',
    '!candidate.length || candidate.length > 128',
    '[candidate isEqualToString:@"."]',
    '[candidate isEqualToString:@".."]',
    '@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"',
    '[allowed invertedSet]',
    '[candidate rangeOfCharacterFromSet:unsafeCharacters].location == NSNotFound',
):
    assert needle in block, needle

for needle in (
    'NSMutableDictionary *scope = [[NSThread currentThread] threadDictionary];',
    'NSString *previous = scope[kCRPkdScopedContainerIDKey];',
    '[scope removeObjectForKey:kCRPkdScopedContainerIDKey];',
    'xpc_dictionary_get_dictionary(request, "rules")',
    'xpc_dictionary_get_string(rules, "crane_containerID")',
    'NSString *verified = CRPkdVerifiedContainerID(container);',
    'scope[kCRPkdScopedContainerIDKey] = verified;',
    'xpc_dictionary_set_value(rules, "crane_containerID", NULL)',
    'xpc_dictionary_set_value(request, "rules", rules)',
    '@try {',
    'original(self, _cmd);',
    '} @finally {',
    'scope[kCRPkdScopedContainerIDKey] = previous;',
):
    assert needle in match, needle

assert match.index('[scope removeObjectForKey:kCRPkdScopedContainerIDKey];') < match.index('xpc_dictionary_get_dictionary(')
assert match.index('NSString *verified = CRPkdVerifiedContainerID(container);') < match.index('xpc_dictionary_set_value(rules, "crane_containerID", NULL)')
assert match.index('xpc_dictionary_set_value(rules, "crane_containerID", NULL)') < match.index('original(self, _cmd);')
assert match.index('original(self, _cmd);') < match.index('} @finally {')
assert match.index('scope[kCRPkdScopedContainerIDKey] = previous;') > match.index('} @finally {')

for needle in (
    'NSArray *result = continuation();',
    'NSMutableDictionary *scope = [[NSThread currentThread] threadDictionary];',
    'NSString *containerIdentifier = scope[kCRPkdScopedContainerIDKey];',
    '[scope removeObjectForKey:kCRPkdScopedContainerIDKey];',
    'if (containerIdentifier && [result isKindOfClass:NSArray.class])',
    '[plugIn crane_updateActiveContainerID:containerIdentifier];',
):
    assert needle in find, needle
assert find.index('NSArray *result = continuation();') < find.index('NSString *containerIdentifier =')
assert find.index('[scope removeObjectForKey:kCRPkdScopedContainerIDKey];') < find.index('[plugIn crane_updateActiveContainerID:')
assert 'gCRPkdContainerID' not in find
assert 'gCRPkdContainerID' not in match

allowed = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
def verified(name):
    return name if isinstance(name, str) and (0 < len(name) <= 128) \
        and name not in ('.', '..') and all(ch in allowed for ch in name) else None

for valid in ("DEFAULT", "C1", "8ACDBA7C-DBA1-4D2D-9E0D-09C60E1E44A1", "import_1"):
    assert verified(valid) == valid
for invalid in (None, "", ".", "..", "../other", "path/child", "path\\child",
                "\n", "bad space", "container é", "A" * 129):
    assert verified(invalid) is None, repr(invalid)

# Independent deterministic interleaving simulation: per-thread scopes
# isolate two overlapping synchronous transactions, and nested scopes
# restore their parent's pending mapping.
class ScopedQuery:
    def __init__(self):
        self.threads = {}
    def enter(self, thread, value):
        previous = self.threads.get(thread)
        self.threads[thread] = verified(value)
        return previous
    def find(self, thread):
        found = self.threads.get(thread)
        self.threads[thread] = None
        return found
    def exit(self, thread, previous):
        self.threads[thread] = previous

s = ScopedQuery()
a_outer = s.enter("A", "C1")
b_outer = s.enter("B", "C2")
assert s.find("A") == "C1", "B must not overwrite A"
assert s.find("B") == "C2", "A must not overwrite B"
s.exit("A", a_outer)
s.exit("B", b_outer)
assert s.find("A") is None and s.find("B") is None

a_outer = s.enter("A", "C1")
nested_previous = s.enter("A", "C3")
assert s.find("A") == "C3"
s.exit("A", nested_previous)
assert s.find("A") == "C1"
s.exit("A", a_outer)
assert s.find("A") is None

# Aborted/no-result request, malformed request, or exception path cannot
# carry its ID into a later ordinary query.
prev = s.enter("A", "C1")
s.exit("A", prev)
next_prev = s.enter("A", None)
assert s.find("A") is None
s.exit("A", next_prev)
prev = s.enter("A", "path/child")
assert s.find("A") is None
s.exit("A", prev)

# A cross-thread database callback is untagged rather than mis-tagged with
# a currently active ID from the original request or a different thread.
prev = s.enter("A", "C1")
assert s.find("worker") is None
s.exit("A", prev)

print("Crane F-12 scoped PlugInKit query contracts: PASS (async/device unverified)")
