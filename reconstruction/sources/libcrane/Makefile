TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# libcrane is loaded by CraneSB, CraneSupport, CranePrefs and the legacy
# CraneShortcuts extension. It is a plain client library, not a tweak.

include $(THEOS)/makefiles/common.mk

# The original installs at /usr/lib/libcrane.dylib
# (LC_ID_DYLIB = /usr/lib/libcrane.dylib) and has no Substrate filter plist.
LIBRARY_NAME = libcrane
libcrane_INSTALL_PATH = /usr/lib

libcrane_FILES  = CRManager.m ../common/CRCommon.m
libcrane_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
libcrane_FRAMEWORKS = Foundation CoreFoundation LocalAuthentication
libcrane_LIBRARIES  = objc

include $(THEOS_MAKE_PATH)/library.mk