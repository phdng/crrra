"""F-08 APNs topic-storage decoding contracts (CraneSupport 0x8B24/0x8C78/0x92C0/0x932C).

Crane's storage key is exactly <hex bytes>/<unsigned 16-bit app ID>.
Original 0x8C78 could read past the end of odd-length hex strings and
0x932C treated malformed/multi-separator strings as successful mappings.
The reconstruction intentionally refuses damaged keys, preserving original
APNs hashes when no valid mapping exists. This is source + independent
behavior modeling, not a real apsd/push-delivery test.
"""
from pathlib import Path

src = (Path(__file__).resolve().parents[1] /
       "sources/support/CRApsd.m").read_text(encoding="utf-8")
native_key = src[src.index("static NSString *CraneApsdTopicStorageKey("):
                 src.index("static NSData *CraneApsdTopicStorageGetCranedHash(")]
hex_fn = src[src.index("static int CraneApsdHexNibble("):
             src.index("/* ------------------------------------------------------------------------- */\n/* Topic helpers")]
decode = native_key[native_key.index("static void CraneApsdDecodeTopicStorageKey("):]
for needle in (
    "static int CraneApsdHexNibble(unichar value)",
    "if (value >= '0' && value <= '9')",
    "if (value >= 'a' && value <= 'f')",
    "if (value >= 'A' && value <= 'F')",
    "if (![string isKindOfClass:NSString.class]",
    "!string.length || (string.length & 1)",
    "[NSMutableData dataWithLength:string.length / 2]",
    "CraneApsdHexNibble([string characterAtIndex:index * 2])",
    "CraneApsdHexNibble([string characterAtIndex:index * 2 + 1])",
    "if (high < 0 || low < 0)",
    "bytes[index] = (unsigned char)((high << 4) | low);",
):
    assert needle in hex_fn, needle
for needle in (
    'CraneApsdHexStringForData(uncranedHash)',
    'if (uncranedHash)',
    '*uncranedHash = nil;',
    '*appId = 0;',
    '[key componentsSeparatedByString:@"/"]',
    'if (parts.count != 2)',
    'NSData *decodedHash = CraneApsdDataForHexString(parts[0]);',
    'if (!decodedHash || !number.length)',
    "if (digit < '0' || digit > '9')",
    "if (parsedID > UINT16_MAX)",
    '*uncranedHash = decodedHash;',
    '*appId = (uint16_t)parsedID;',
):
    assert needle in native_key, needle
assert native_key.index('if (parts.count != 2)') < native_key.index('CraneApsdDataForHexString(parts[0])')
assert native_key.index('if (parsedID > UINT16_MAX)') < native_key.index('*uncranedHash = decodedHash;')
assert 'NSNumberFormatter' not in decode
assert 'strtoul(' not in hex_fn
assert 'malloc(' not in hex_fn

# Native CraneSupport 0x8854 expands a legacy signed-byte hex
# representation (ffffffXX) and 0x8E1C retrieves that value via Keychain.
# Malformed account entries cannot be promoted into false topic mappings.
conversion = src[src.index("static NSMutableData *CraneApsdDataForStringRepresentation("):
                 src.index("static NSString *CraneApsdHexStringForData(")]
lookup_keychain = src[src.index("static NSMutableData *CraneApsdFetchTopicHash("):
                      src.index("/* ------------------------------------------------------------------------- */\n/* CraneSB-loaded gate")]
for needle in (
    'if (![string isKindOfClass:NSString.class] || !string.length)',
    '[remaining hasPrefix:@"ffffff"]',
    'if (remaining.length < 2)',
    'int high = CraneApsdHexNibble(hi);',
    'int low = CraneApsdHexNibble(lo);',
    'if (high < 0 || low < 0)',
    'unsigned char byte = (unsigned char)((high << 4) | low);',
    'if (representation.length == 2)',
):
    assert needle in conversion, needle

for needle in (
    '[domain isKindOfClass:NSString.class]',
    '[token isKindOfClass:NSData.class]',
    'SecItemCopyMatching(',
    '[entry isKindOfClass:NSDictionary.class]',
    '[persisted isKindOfClass:NSData.class]',
    '[account isKindOfClass:NSString.class]',
    'CraneApsdDataForStringRepresentation(representation)',
    'if (candidate.length)',
):
    assert needle in lookup_keychain, needle

response = src[src.index("static void CraneApsdHandleAppTokenGenerateResponse("):
               src.index("static void CraneApsdHandleMessage(")]
assert '[topicHash isKindOfClass:NSData.class]' in response
assert '[appIdNumber isKindOfClass:NSNumber.class]' in response
assert 'appIdNumber.unsignedLongLongValue > UINT16_MAX' in response
assert response.index('if (![topicHash isKindOfClass:NSData.class]') < response.index('CraneApsdTopicStorageGetCranedHash(')
incoming = src[src.index("static void CraneApsdHandleMessage("):
               src.index("/* ------------------------------------------------------------------------- */\n/* Hook wrappers")]
assert '[topicHash isKindOfClass:NSData.class]' in incoming
assert '[token isKindOfClass:NSData.class]' in incoming
assert incoming.index('[topicHash isKindOfClass:NSData.class]') < incoming.index('CraneApsdFetchTopicHash(domain, token, courier)')

def valid_account_hash(text):
    # The prefix is a legacy signed-byte representation. The special-case
    # sign-extension output is handled by Apple's APS formatter on-device.
    if not isinstance(text, str) or not text:
        return None
    remaining = text
    result = bytearray()
    while remaining:
        if remaining.startswith("ffffff"):
            remaining = remaining[6:]
        if len(remaining) < 2 or any(c not in "0123456789abcdefABCDEF" for c in remaining[:2]):
            return None
        result.append(int(remaining[:2], 16))
        remaining = remaining[2:]
    return bytes(result)

assert valid_account_hash("00ff") == bytes.fromhex("00ff")
assert valid_account_hash("ffffff80") == bytes.fromhex("80")
assert valid_account_hash("abcdef") == bytes.fromhex("abcdef")
for text in ("", "f", "0xz1", "q0", "ffffff", "00f", None):
    assert valid_account_hash(text) is None, repr(text)

# Only a successfully decoded value can influence getUncranedHash and the
# incoming APSProtocolTopicHash rewrite; nil leaves the message unchanged.
lookup = src[src.index("static NSData *CraneApsdTopicStorageGetUncranedHash("):
             src.index("static void CraneApsdTopicStorageWritePair(")]
assert "CraneApsdDecodeTopicStorageKey(key, &uncraned, NULL);" in lookup
token = src[src.index("static void CraneApsdSendAppTokenGenerate("):
            src.index("static void CraneApsdSendTokenGenerate(")]
assert "if (uncraned)" in token
assert "effectiveHash = uncraned;" in token
incoming = src[src.index("static void CraneApsdHandleMessage("):
               src.index("/* ------------------------------------------------------------------------- */\n/* Hook wrappers")]
assert 'if (!actualTopicHash || [actualTopicHash isEqual:topicHash])' in incoming
assert "continuation(message);" in incoming

def decode_key(key):
    if not isinstance(key, str):
        return None
    parts = key.split("/")
    if len(parts) != 2:
        return None
    h, decimal_id = parts
    if not h or len(h) % 2 or any(ch not in "0123456789abcdefABCDEF" for ch in h):
        return None
    if not decimal_id or any(ch not in "0123456789" for ch in decimal_id):
        return None
    id_value = 0
    for ch in decimal_id:
        id_value = id_value * 10 + ord(ch) - ord('0')
        if id_value > 65535:
            return None
    return bytes.fromhex(h), id_value

for key, hash_value, app_id in [
    ("00ff/0", bytes.fromhex("00ff"), 0),
    ("A1B2c3/7", bytes.fromhex("a1b2c3"), 7),
    ("0123456789abcdef/65535", bytes.fromhex("0123456789abcdef"), 65535),
    ("aabb/00001", bytes.fromhex("aabb"), 1),
]:
    assert decode_key(key) == (hash_value, app_id)
for key in (
    None, "", "/", "aabb", "/7", "ab/", "abc/4", "gg/1",
    "0x0a/5", "ab -/1", "aabb/6/9", "aabb/-1", "aabb/+1",
    "aabb/65536", "aabb/9999999999999999999", "aabb/12.0",
    "aabb/１２", "aabb/\n",
):
    assert decode_key(key) is None, repr(key)

# Guard means invalid keys yield no remapping, not a fabricated zero hash.
sample = bytes.fromhex("aabb")
stored = {"aabb/7": b"craned"}
def translate(stored, craned):
    for key, value in stored.items():
        if value == craned:
            decoded = decode_key(key)
            return decoded[0] if decoded else None
    return None
assert translate(stored, b"craned") == sample
assert translate({"aab/7": b"craned"}, b"craned") is None
assert translate(stored, b"unmatched") is None

print("Crane F-08 APNs topic-key strict decoding contracts: PASS (device unverified)")
