TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# Roothide-only dependency-free loader discriminator. This is intentionally
# built as a plain dynamic library rather than tweak.mk so it does NOT acquire
# the tweak backend's Substrate/ElleKit dependency. TweakLoader still discovers
# it through the sibling .plist staged beside the dylib.
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = CraneSupportProbeBare
CraneSupportProbeBare_FILES = CRSupportProbeBare.c
CraneSupportProbeBare_CFLAGS = -fvisibility=hidden
CraneSupportProbeBare_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
