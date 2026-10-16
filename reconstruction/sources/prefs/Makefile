TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# CranePrefs.bundle/CranePrefs - the Settings UI. The original hard-links
# Preferences.framework. CI's stock iOS SDK omits that private-framework stub,
# so reconstruction/vendor supplies a linker-only TBD with the same install name.
BUNDLE_NAME = CranePrefs
CranePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk

CranePrefs_FILES  = CRPreferences.m CRCredits.m CRRootSuggestions.m CRChoicyEditor.m CRBackupNativeCore.m CRBackupArchiveSurvey.m CRBackupNativeFixtureWriter.m CRBackupNativeFixtureCollector.m CRBackupNativeSourcePreflight.m CRBackupNativeManagerPreflight.m CRBackupNativeTypedPreflight.m CRBackupDisposableDiagnostic.m ../common/CRCommon.m
CranePrefs_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CranePrefs_CFLAGS += -I$(THEOS_PROJECT_DIR)/layout/Library/PreferenceBundles/CranePrefs.bundle
CranePrefs_FRAMEWORKS = Foundation CoreFoundation UIKit Security CoreGraphics LocalAuthentication MobileCoreServices
CranePrefs_PRIVATE_FRAMEWORKS = Preferences
# Current CranePrefs source does not call AltList symbols. The roothide
# toolchain does not provide AltList.framework, so avoid an unused hard link
# there; preserve the recovered Rootful link requirement unchanged.
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
CranePrefs_EXTRA_FRAMEWORKS = AltList
endif
CranePrefs_LIBRARIES  = crane z iconv
CranePrefs_LDFLAGS += -F$(THEOS_PROJECT_DIR)/vendor -L$(THEOS_OBJ_DIR)

include $(THEOS_MAKE_PATH)/bundle.mk