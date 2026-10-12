"""F-12 PlugInKit private container rule validation and stale-state reset.

CraneSupport 0xFD70 consumes "crane_containerID" from XPC rules into a
process-global string and 0xF174 applies it to returned plugins. If a
transaction does not reach the result callback, old state can leak to an
unrelated query. This reconstruction clears it before every new match and
rejects unsafe components, while preserving the original private key removal
and UUID/non-UUID imported container compatibility.

This does NOT solve overlapping transactions: the recovered binary uses a
global and does not expose a transaction->database lookup identity. This
is a sequential-query safety improvement only; runtime pkd tests required.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = (root / "sources/support/CRPkd.m").read_text(encoding="utf-8")
begin = src.index("static NSString *CRPkdVerifiedContainerID(")
end = src.index("typedef NSArray *(^CRPkdFindPlugInsContinuation)", begin)
block = src[begin:end]
match = block[block.index("static void CRPkdMatchPlugIns("):]

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
    'gCRPkdContainerID = nil;',
    'xpc_dictionary_get_dictionary(request, "rules")',
    'xpc_dictionary_get_string(rules, "crane_containerID")',
    'gCRPkdContainerID = CRPkdVerifiedContainerID(container);',
    'xpc_dictionary_set_value(rules, "crane_containerID", NULL)',
    'xpc_dictionary_set_value(request, "rules", rules)',
    'original(self, _cmd);',
):
    assert needle in match, needle

assert match.index('gCRPkdContainerID = nil;') < match.index('xpc_dictionary_get_dictionary(')
assert match.index('gCRPkdContainerID = CRPkdVerifiedContainerID(container);') < match.index('xpc_dictionary_set_value(rules, "crane_containerID", NULL)')
assert match.index('xpc_dictionary_set_value(rules, "crane_containerID", NULL)') < match.index('original(self, _cmd);')

result = src[src.index("static NSArray *CRPkdFindPlugIns("):
             src.index("static id CRPkdFindPlugIns1(")]
assert 'NSString *containerIdentifier = gCRPkdContainerID;' in result
assert '[plugIn crane_updateActiveContainerID:containerIdentifier];' in result
assert 'gCRPkdContainerID = nil;' in result

allowed = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
def verified(name):
    return name if isinstance(name, str) and (0 < len(name) <= 128) \
        and name not in ('.', '..') and all(ch in allowed for ch in name) else None

for valid in ("DEFAULT", "C1", "8ACDBA7C-DBA1-4D2D-9E0D-09C60E1E44A1", "import_1"):
    assert verified(valid) == valid, valid
for invalid in (None, "", ".", "..", "../other", "path/child", "path\\child",
                "\n", "bad space", "container é", "A" * 129):
    assert verified(invalid) is None, repr(invalid)

# Independent sequential match->find model: missing, unsafe, or cancelled
# private rules cannot reuse a stale nondefault container.
state = "OLD_CONTAINER"
def match_request(rule):
    return verified(rule)  # clears previous state unconditionally

state = match_request(None)
assert state is None
state = match_request("C1")
assert state == "C1"
state = None  # find result consumes the matching rule
state = match_request("C2")
assert state == "C2"
state = match_request("path/child")
assert state is None
state = match_request("import_1")
assert state == "import_1"
state = match_request(None)
assert state is None

print("Crane F-12 pkd private-rule stale-state contracts: PASS (concurrent queries unverified)")
