TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# Roothide-only diagnostic libraries. These are intentionally plain dylibs,
# not Substrate-linked tweak targets: each has only libSystem/roothide scheme
# load commands plus a matching MobileSubstrate filter plist. Their sole
# purpose is to distinguish daemon-injector/filter failure from CraneSupport
# Mach-O dependency/load failure on devices where CraneSupport never reaches
# its constructor.
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = CraneSupportProbeFlags CraneSupportProbePlain

CraneSupportProbeFlags_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
CraneSupportProbeFlags_FILES = CRSupportProbeFlags.c
CraneSupportProbeFlags_CFLAGS = -fvisibility=hidden

CraneSupportProbePlain_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
CraneSupportProbePlain_FILES = CRSupportProbePlain.c
CraneSupportProbePlain_CFLAGS = -fvisibility=hidden

include $(THEOS_MAKE_PATH)/library.mk
