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

# Rootful retains its existing dependency metadata. Roothide uses a
# different package namespace, and AltList/Choicy/Activator are optional
# integrations (not hard-linked into the Roothide CranePrefs build).
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
export ADDITIONAL_CFLAGS += -DCRANE_ROOTHIDE=1
THEOS_PACKAGE_DEPENDS = mobilesubstrate, firmware
else
THEOS_PACKAGE_DEPENDS = mobilesubstrate, ellekit, libhooker, firmware, \
                         altlist, activator, choicy
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += sources/maindylib sources/libcrane sources/cranehelperd \
               sources/cranehelperd_start sources/cranesb sources/support sources/prefs

# Temporary roothide-only daemon-injection probes. Keep them outside rootful
# fidelity builds: they are diagnostic artifacts, not recovered Crane payload.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SUBPROJECTS += sources/supportprobe sources/supportprobe-bare
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

# dpkg executes postinst as the installer user; Windows checkouts may lose +x.
# DEBIAN is copied by deb.mk, before this packaging prerequisite completes.
before-package:: $(THEOS_STAGING_DIR)/DEBIAN
	@chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"

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
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	@cp -f "$(THEOS_PROJECT_DIR)/sources/supportprobe/CraneSupportProbeFlags.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CraneSupportProbeFlags.plist"
	@cp -f "$(THEOS_PROJECT_DIR)/sources/supportprobe/CraneSupportProbePlain.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CraneSupportProbePlain.plist"
	@cp -f "$(THEOS_PROJECT_DIR)/sources/supportprobe-bare/CraneSupportProbeBare.plist" \
	       "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/CraneSupportProbeBare.plist"
endif
	@echo "== staged layout =="
	@find "$(THEOS_STAGING_DIR)" -type f | sed "s|$(THEOS_STAGING_DIR)/||" | sort