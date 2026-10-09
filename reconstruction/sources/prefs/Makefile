TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# CranePrefs.bundle/CranePrefs - the Settings UI. The original links AltList and
# Preferences, so both are hard requirements here (see the file header).
TWEAK_NAME = CranePrefs

include $(THEOS)/makefiles/common.mk

CranePrefs_FILES  = CRPreferences.m ../common/CRCommon.m
CranePrefs_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CranePrefs_CFLAGS += -I$(THEOS_PROJECT_DIR)/layout/Library/PreferenceBundles/CranePrefs.bundle
CranePrefs_FRAMEWORKS = Foundation CoreFoundation UIKit Security \
                        MobileCoreServices CoreGraphics Preferences
CranePrefs_LIBRARIES  = objc libcrane.dylib z iconv

include $(THEOS_MAKE_PATH)/tweak.mk