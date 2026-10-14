"""Roothide-only CraneSupport daemon injection probe contract.

The production CraneSupport constructor never runs on the iOS 15.8.8 device.
Two temporary Theos tweaks share the exact seven daemon Executables list: one
preserves the recovered Flags=1 and one omits Flags. They deliberately use the
same tweak pipeline as CraneSupport while keeping their constructor bodies free
of Crane/Foundation/keychain logic. Device outcomes:

- neither probe loads -> Dopamine/roothide daemon injection path or platform
- plain loads, flags1 does not -> Flags=1 loader semantics
- both probes load, CraneSupport does not -> CraneSupport Mach-O/load dependency
"""

from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
master = (root / "Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
probe_mk = (root / "sources/supportprobe/Makefile").read_text(encoding="utf-8")
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
    assert f"CraneSupportProbe: variant=" in (flags_source + plain_source)
    assert f"pkg/Library/MobileSubstrate/DynamicLibraries/{name}.dylib" in workflow

for source, variant in ((flags_source, "flags1"), (plain_source, "plain")):
    assert "#include <os/log.h>" in source
    assert "#include <Foundation" not in source
    assert "CRManager" not in source
    assert "audit_token" not in source
    assert "os_log(OS_LOG_DEFAULT," in source
    assert f"variant={variant} constructor" in source

assert "_FRAMEWORKS" not in probe_mk
for forbidden in ("libcrane", "bsm.0", "Foundation", "CoreFoundation", "Security"):
    assert forbidden not in probe_mk

print("Crane roothide daemon injection probe contracts: PASS (device diagnostic pending)")
