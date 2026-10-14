"""Roothide-only CraneSupport daemon injection probe contract.

The production CraneSupport constructor never runs on the iOS 15.8.8 device.
Two temporary Theos tweaks share the exact seven daemon Executables list: one
preserves the recovered Flags=1 and one omits Flags. They deliberately use the
same tweak pipeline as CraneSupport while keeping their constructor bodies free
of Crane/Foundation/keychain logic. Device outcomes:

A positive on-demand SpringBoard-notified reply proves a live probe is
mapped into that daemon. Lack of replies alone is inconclusive because Darwin
notify registration or delivery can itself be sandbox-restricted.

- plain replies but flags1 does not -> investigate Flags=1 loader semantics
- both reply but CraneSupport registry is absent -> investigate its Mach-O,
  libSandy transport and runtime report separately
"""

from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
master = (root / "Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
probe_mk = (root / "sources/supportprobe/Makefile").read_text(encoding="utf-8")
wire = (root / "sources/supportprobe/CRSupportProbeProtocol.h").read_text(encoding="utf-8")
springboard = (root / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
flags_source = (root / "sources/supportprobe/CRSupportProbeFlags.c").read_text(encoding="utf-8")
plain_source = (root / "sources/supportprobe/CRSupportProbePlain.c").read_text(encoding="utf-8")

processes = [
    "cfprefsd", "containermanagerd", "securityd", "pkd",
    "lsd", "accountsd", "apsd",
]

flags = plistlib.loads(
    (root / "sources/supportprobe/CraneSupportProbeFlags.plist").read_bytes()
)
plain = plistlib.loads(
    (root / "sources/supportprobe/CraneSupportProbePlain.plist").read_bytes()
)

assert flags == {"Filter": {"Executables": processes, "Flags": 1}}
assert plain == {"Filter": {"Executables": processes}}
assert "ifeq ($(THEOS_PACKAGE_SCHEME),roothide)" in master
assert "SUBPROJECTS += sources/supportprobe" in master
assert master.index("ifeq ($(THEOS_PACKAGE_SCHEME),roothide)") < master.index(
    "SUBPROJECTS += sources/supportprobe"
)
assert "TWEAK_NAME = CraneSupportProbeFlags CraneSupportProbePlain" in probe_mk
assert "include $(THEOS_MAKE_PATH)/tweak.mk" in probe_mk
assert "include $(THEOS_MAKE_PATH)/library.mk" not in probe_mk
for name in ("CraneSupportProbeFlags", "CraneSupportProbePlain"):
    assert name in probe_mk
    assert f"{name}_LIBRARIES = substrate" in probe_mk
    assert f"{name}_CFLAGS = -fvisibility=hidden -fblocks" in probe_mk
    assert f"CraneSupportProbe: variant=" in (flags_source + plain_source)
    assert f"pkg/Library/MobileSubstrate/DynamicLibraries/{name}.dylib" in workflow

for source, variant in ((flags_source, "flags1"), (plain_source, "plain")):
    assert "#include <os/log.h>" in source
    assert "#include <Foundation" not in source
    assert "CRManager" not in source
    assert "audit_token" not in source
    assert "os_log(OS_LOG_DEFAULT," in source
    assert f"variant={variant} constructor" in source
    assert "#include <notify.h>" in source
    assert '#include "CRSupportProbeProtocol.h"' in source
    assert "notify_register_dispatch(" in source
    assert "notify_post(reply);" in source
    assert f'"%s.{variant}.%s"' in source
    assert "getprogname()" in source
    assert "CraneSupportProbe: variant=" in source
    assert "remove(" not in source
    assert "unlink(" not in source

assert '"com.opa334.cranereconstruction.supportprobe.ping"' in wire
assert '"com.opa334.cranereconstruction.supportprobe.reply"' in wire
assert '#include "../supportprobe/CRSupportProbeProtocol.h"' in springboard
assert 'static int gSupportProbeReplyTokens[14];' in springboard
assert "static void CRRegisterSupportProbeReplies(void)" in springboard
assert "static void CRRequestSupportProbeReplies(void)" in springboard
assert "notify_register_dispatch(" in springboard
assert "notify_post(CR_SUPPORT_PROBE_PING)" in springboard
assert 'CraneSB: support probe reply variant=%@ process=%@' in springboard
assert 'CraneSB: support probe ping status=%u' in springboard
# Observer registration happens early in SpringBoard, then each non-default
# launch requests a ping. Only CraneSupport's authenticated runtime report
# can influence insurance; probe notifications must NEVER grant containers.
assert springboard.index("CRRegisterSupportProbeReplies();") < springboard.index(
    'CRReportRuntimeInjection(@"CraneSB", nil);',
    springboard.index("static void CRInitFunc(void)")
)
assert "CRRequestSupportProbeReplies();" in springboard
assert 'if (insuranceOK)' in springboard
assert 'CRReportRuntimeInjection(@"CraneSupport", nil);' not in springboard
assert "_FRAMEWORKS" not in probe_mk
for forbidden in ("libcrane", "bsm.0", "Foundation", "CoreFoundation", "Security"):
    assert forbidden not in probe_mk

print("Crane roothide daemon injection probe contracts: PASS (device diagnostic pending)")
