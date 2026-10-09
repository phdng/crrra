TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# CranePrefs.bundle/CranePrefs - the Settings UI. The original links AltList and
# Preferences, so both are hard requirements here (see the file header).
BUNDLE_NAME = CranePrefs
CranePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk

CranePrefs_FILES  = CRPreferences.m ../common/CRCommon.m
CranePrefs_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CranePrefs_CFLAGS += -I$(THEOS_PROJECT_DIR)/layout/Library/PreferenceBundles/CranePrefs.bundle
CranePrefs_FRAMEWORKS = Foundation CoreFoundation UIKit Security CoreGraphics LocalAuthentication MobileCoreServices
CranePrefs_PRIVATE_FRAMEWORKS = Preferences
CranePrefs_EXTRA_FRAMEWORKS = AltList
CranePrefs_LIBRARIES  = crane z iconv
CranePrefs_LDFLAGS += -L$(THEOS_OBJ_DIR)

include $(THEOS_MAKE_PATH)/bundle.mk