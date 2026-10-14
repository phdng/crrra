"""Archived Roothide CraneSupport daemon-injection probe contract.

The flags/plain/bare probes were temporary diagnostics used while the real
CraneSupport loader/fix-up path was unknown. Device validation on 2026-10-14
proved the production helper fix-up and insurance path healthy, so the probes
must remain OUT of normal package, SpringBoard and helper wiring.

Keep their sources as a reusable manual diagnostic harness. This contract
preserves their safety/shape while preventing accidental production shipping.
"""

from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
master = (root / "Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
probe_mk = (root / "sources/supportprobe/Makefile").read_text(encoding="utf-8")
bare_mk = (root / "sources/supportprobe-bare/Makefile").read_text(encoding="utf-8")
bare_source = (root / "sources/supportprobe-bare/CRSupportProbeBare.c").read_text(encoding="utf-8")
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
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
bare = plistlib.loads(
    (root / "sources/supportprobe-bare/CraneSupportProbeBare.plist").read_bytes()
)

# Archived harness still mirrors the exact target set used during diagnosis.
assert flags == {"Filter": {"Executables": processes, "Flags": 1}}
assert plain == {"Filter": {"Executables": processes}}
assert bare == {"Filter": {"Executables": processes}}
assert "TWEAK_NAME = CraneSupportProbeFlags CraneSupportProbePlain" in probe_mk
assert "include $(THEOS_MAKE_PATH)/tweak.mk" in probe_mk
assert "include $(THEOS_MAKE_PATH)/library.mk" not in probe_mk
assert "LIBRARY_NAME = CraneSupportProbeBare" in bare_mk
assert "include $(THEOS_MAKE_PATH)/library.mk" in bare_mk
assert "include $(THEOS_MAKE_PATH)/tweak.mk" not in bare_mk

# The bare discriminator remains dependency-free and side-effect-free.
assert "#include" not in bare_source
for forbidden in (
    "notify_register", "notify_post(", "os_log(", "getprogname(",
    "MSHook", "dlopen(", "dlsym(", "CRManager",
):
    assert forbidden not in bare_source, forbidden
assert "CRSupportProbeBareInit" in bare_source

# flags/plain remain constructor-only diagnostics, not Crane product logic.
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
    assert "remove(" not in source
    assert "unlink(" not in source

assert '"com.opa334.cranereconstruction.supportprobe.ping"' in wire
assert '"com.opa334.cranereconstruction.supportprobe.reply"' in wire

# Production wiring must stay clean now that real fix-up is device-proven.
for forbidden in (
    "SUBPROJECTS += sources/supportprobe",
    "CraneSupportProbeFlags.plist",
    "CraneSupportProbePlain.plist",
    "CraneSupportProbeBare.plist",
):
    assert forbidden not in master, forbidden

for forbidden in (
    '#include "../supportprobe/CRSupportProbeProtocol.h"',
    "gSupportProbeReplyTokens",
    "CRRegisterSupportProbeReplies",
    "CRRequestSupportProbeReplies",
    "support probe reply",
    "support probe ping",
):
    assert forbidden not in springboard, forbidden

for forbidden in (
    "CraneSupportProbeFlags.dylib",
    "CraneSupportProbePlain.dylib",
    "CraneSupportProbeBare.dylib",
    "flags=%d",
    "plain=%d",
    "bare=%d",
):
    assert forbidden not in helper, forbidden

for forbidden in (
    "CraneSupportProbeFlags.dylib",
    "CraneSupportProbePlain.dylib",
    "CraneSupportProbeBare.dylib",
    "Missing daemon injection probe",
    "Bare probe unexpectedly links a jailbreak library",
):
    assert forbidden not in workflow, forbidden

# Keep the real Roothide linkage check for production Crane payloads.
assert "Invalid roothide jailbreak dependency load path" in workflow
assert "@loader_path/.jbroot/" in workflow
assert "'pkg/Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib'" in workflow
assert "'pkg/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib'" in workflow

print("Crane archived roothide daemon probe contract: PASS (not shipped)")
