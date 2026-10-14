TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# Roothide-only daemon-injection probes. Build these through Theos' tweak
# pipeline (not library.mk): Dopamine/roothide tweak loaders are entitled to
# treat staged tweak dylibs differently from arbitrary libraries. The probe
# bodies remain constructor-only so any difference from CraneSupport is limited
# to its real dependencies/hooks rather than application logic.
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CraneSupportProbeFlags CraneSupportProbePlain

CraneSupportProbeFlags_FILES = CRSupportProbeFlags.c
CraneSupportProbeFlags_CFLAGS = -fvisibility=hidden -fblocks
CraneSupportProbeFlags_LIBRARIES = substrate

CraneSupportProbePlain_FILES = CRSupportProbePlain.c
CraneSupportProbePlain_CFLAGS = -fvisibility=hidden -fblocks
CraneSupportProbePlain_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
