TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# CraneSupport.dylib. Substrate filter (CONFIRMED_STATIC from CraneSupport.plist):
#   Executables = [cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd,
#                  apsd], Flags = 1
TWEAK_NAME = CraneSupport
INSTALL_TARGET_PROCESSES = cfprefsd, containermanagerd, securityd, pkd, lsd, \
                            accountsd, apsd

include $(THEOS)/makefiles/common.mk

CraneSupport_FILES  = CRSupport.m ../common/CRCommon.m
CraneSupport_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CraneSupport_FRAMEWORKS = Foundation CoreFoundation Security AppSupport CoreData
CraneSupport_FRAMEWORKS += LocalAuthentication
CraneSupport_LIBRARIES  = objc libcrane.dylib libbsm.0.dylib

include $(THEOS_MAKE_PATH)/tweak.mk