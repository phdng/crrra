# Crane reconstruction — master Theos makefile
#
# Every install path, filter and dependency below is taken from the recovered
# package layout; see analysis/package_inventory.md, analysis/preference_schema.md
# and analysis/hook_reconstruction.md for the evidence behind each line.
#
# Verified against the original package:
#   * 6 Mach-O binaries, each a fat arm64 + arm64e binary
#   * 3 Substrate load filters, 1 launchd job, 5 libSandy profiles
#   * LC_VERSION_MIN_IPHONEOS 11.0 / SDK 14.5.0 on all non-app binaries
#   * settings bundle: NSPrincipalClass CRPRootListController, prefs domain
#     com.opa334.craneprefs

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest
export PLATFORM_IOS = 14.0
export IPHONEOS_DEPLOYMENT_TARGET = 14.0
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_PACKAGE_BASE_VERSION = 6.0
export THEOS_PACKAGE_VERSION = 6.0

# Dependency packages present on a standard jailbreak. `firmware` is required
# because AltList.framework (linked by CranePrefs) lives in it.
THEOS_PACKAGE_DEPENDS = mobilesubstrate, ellekit, libhooker, firmware, \
                         altlist, activator, choicy

SUBPROJECTS += sources/maindylib sources/libcrane sources/cranehelperd \
               sources/cranesb sources/support sources/prefs

include $(THEOS)/makefiles/common.mk

.PHONY: layout package stage

package-stage::
	@# Reproduce the original layout exactly. The main dylib carries a
	@# deliberate LEADING SPACE in its filename (see analysis/hook_reconstruction.md
	@# section 1 and the CHOICYLOADER_SUGGESTION_MESSAGE localization key).
	@mkdir -p "$(THEOS_STAGING_DIR_NATIVE)/Library/MobileSubstrate/DynamicLibraries"
	@for f in $(THEOS_PACKAGE_DIR_BASE)/Library/MobileSubstrate/DynamicLibraries/*.dylib; do \
	    if [ -e "$$f" ]; then \
	        case "$$f" in \
	          *"/ Crane.dylib") cp "$$f" "$(THEOS_STAGING_DIR_NATIVE)/Library/MobileSubstrate/DynamicLibraries/ Crane.dylib" ;; \
	          *) cp "$$f" "$(THEOS_STAGING_DIR_NATIVE)/Library/MobileSubstrate/DynamicLibraries/" ;; \
	        esac; \
	    fi; \
	done
	@for f in $(THEOS_PACKAGE_DIR_BASE)/Library/MobileSubstrate/DynamicLibraries/*.plist; do \
	    if [ -e "$$f" ]; then \
	        case "$$f" in \
	          *"/ Crane.plist") cp "$$f" "$(THEOS_STAGING_DIR_NATIVE)/Library/MobileSubstrate/DynamicLibraries/ Crane.plist" ;; \
	          *) cp "$$f" "$(THEOS_STAGING_DIR_NATIVE)/Library/MobileSubstrate/DynamicLibraries/" ;; \
	        esac; \
	    fi; \
	done
	@cp -a layout/. "$(THEOS_STAGING_DIR_NATIVE)/"

stage::
	@echo "== staged layout =="
	@find "$(THEOS_STAGING_DIR_NATIVE)" -type f | sed "s|$(THEOS_STAGING_DIR_NATIVE)/||" | sort