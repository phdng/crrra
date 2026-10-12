"""Guard cfprefsd container-pref filename isolation (CraneSupport 0xADF0, 0xB4D0).

B4D0 writes UTF-16 code units directly to an 0x400-byte C buffer and does
not terminate it when full. This reconstruction preserves ASCII results but
rejects oversized rewrites and converts non-ASCII names as UTF-8.

Static/model check only: it does not execute on iOS cfprefsd.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "sources/support/CRCfprefs.m").read_text(encoding="utf-8")

hook = source[
    source.index("static uintptr_t CRPrefsGetPathForTriplet("):
    source.index("/* ------------------------------------------------------------------------- */\n/* Hook installation / libundirect compatibility")
]

assert 'MSFindSymbol(coreFoundation, "__CFPrefsGetPathForTriplet")' in source
assert 'static uintptr_t CRPrefsGetPathForTriplet(uintptr_t a1,' in hook
assert 'gOrigCFPrefsGetPathForTriplet(a1, a2, a3, a4, pathBuffer)' in hook
assert 'if (!pathBuffer || (uint32_t)result == 0)' in hook
assert 'CranePrefsTripletContainerKey' in hook
assert 'NSString *domain = lastComponent.stringByDeletingPathExtension;' in hook
assert 'stringWithFormat:@"%@.c_r_a_n_e.%@.plist"' in hook
assert '#import <string.h>' in source

# Buffer rewrite must be all-or-nothing: no partial byte writes, no
# NSString.length used as the number of bytes for a UTF-8 path.
assert 'NSData *utf8 = [rewritten dataUsingEncoding:NSUTF8StringEncoding];' in hook
assert 'if (!utf8 || utf8.length == 0 || utf8.length >= 0x400)' in hook
assert 'memcpy(pathBuffer, utf8.bytes, utf8.length);' in hook
assert "pathBuffer[utf8.length] = '\\0';" in hook
assert hook.index('utf8.length >= 0x400') < hook.index('memcpy(pathBuffer')
assert hook.index('memcpy(pathBuffer') < hook.index("pathBuffer[utf8.length]")
assert '(char)[rewritten characterAtIndex:index]' not in hook
assert 'NSUInteger copied = MIN(length, (NSUInteger)0x400);' not in hook

# Model bounded pathname rewriting, comparing UTF-8 bytes, not UTF-16
# units or Python Unicode code points.
def rewritten_if_fits(path, active):
    parent, slash, leaf = path.rpartition("/")
    if not slash or not leaf or not active:
        return path
    domain = leaf.rsplit(".", 1)[0]
    candidate = parent + "/" + domain + ".c_r_a_n_e." + active + ".plist"
    encoded = candidate.encode("utf-8")
    return candidate if 0 < len(encoded) < 0x400 else path

assert rewritten_if_fits("/var/mobile/Library/Preferences/com.example.plist", "C1") == (
    "/var/mobile/Library/Preferences/com.example.c_r_a_n_e.C1.plist"
)
assert rewritten_if_fits("/Prefs/naïve.plist", "C1") == "/Prefs/naïve.c_r_a_n_e.C1.plist"
assert rewritten_if_fits("/Prefs/日本語.plist", "C1") == "/Prefs/日本語.c_r_a_n_e.C1.plist"
assert rewritten_if_fits("/Prefs/app.plist", "C" * 1024) == "/Prefs/app.plist"
assert rewritten_if_fits("/Prefs/app.plist", "C" * 1003) == "/Prefs/app.plist"

print("Crane F-05 cfprefsd UTF-8 bounded rewrite contracts: PASS (device unverified)")
