# Crane reconstruction — master Theos makefile
#
# Every install path, filter and dependency below is taken from the recovered
# package layout; see analysis/package_inventory.md, analysis/preference_schema.md
# and analysis/hook_reconstruction.md for the evidence behind each line.
#
# Verified against the original package:
#   * 7 reconstructed Mach-O targets: 5 fat arm64 + arm64e libraries/bundles
#     and 2 thin arm64 executables
#   * 3 Substrate load filters, 1 launchd job, 5 libSandy profiles
#   * LC_VERSION_MIN_IPHONEOS 11.0 / SDK 14.5.0 on all non-app binaries
#   * settings bundle: NSPrincipalClass CRPRootListController, prefs domain
#     com.opa334.craneprefs

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:11.0
export IPHONEOS_DEPLOYMENT_TARGET = 11.0
export GO_EASY_ON_ME = 1
export THEOS_PACKAGE_BASE_VERSION = 6.0

# Dependency packages present on a standard jailbreak. `firmware` is required
# because AltList.framework (linked by CranePrefs) lives in it.
THEOS_PACKAGE_DEPENDS = mobilesubstrate, ellekit, libhooker, firmware, \
                         altlist, activator, choicy

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += sources/maindylib sources/libcrane sources/cranehelperd \
               sources/cranehelperd_start sources/cranesb sources/support sources/prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@# Theos requires a filter plist beside every tweak Makefile, so each tweak
	@# stages an XML copy. Restore the recovered binary filter plists from layout/
	@# afterwards, and preserve the deliberate LEADING SPACE on the main pair.
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	@if [ -e "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Crane.dylib" ]; then \
	    mv "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Crane.dylib" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ Crane.dylib"; \
	fi
	@rm -f "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Crane.plist"
	@cp -f "$(THEOS_PROJECT_DIR)/layout/Library/MobileSubstrate/DynamicLibraries/ Crane.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ Crane.plist"
	@cp -f "$(THEOS_PROJECT_DIR)/layout/Library/MobileSubstrate/DynamicLibraries/CraneSB.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CraneSB.plist"
	@cp -f "$(THEOS_PROJECT_DIR)/layout/Library/MobileSubstrate/DynamicLibraries/CraneSupport.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CraneSupport.plist"
	@echo "== staged layout =="
	@find "$(THEOS_STAGING_DIR)" -type f | sed "s|$(THEOS_STAGING_DIR)/||" | sort