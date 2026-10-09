TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# CraneSupport.dylib. Substrate filter (CONFIRMED_STATIC from CraneSupport.plist):
#   Executables = [cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd,
#                  apsd], Flags = 1
TWEAK_NAME = CraneSupport
INSTALL_TARGET_PROCESSES = cfprefsd containermanagerd securityd pkd lsd \
                            accountsd apsd

include $(THEOS)/makefiles/common.mk

CraneSupport_FILES  = CRSupport.m CRCfprefs.m CRMCM.m CRPkd.m ../common/CRCommon.m
CraneSupport_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CraneSupport_FRAMEWORKS = Foundation CoreFoundation Security CoreData LocalAuthentication
# AppSupport is present in the original binary's load commands, but the
# reconstructed source currently has no AppSupport symbol references.
CraneSupport_LIBRARIES  = crane bsm.0 substrate
CraneSupport_LDFLAGS += -L$(THEOS_OBJ_DIR)

include $(THEOS_MAKE_PATH)/tweak.mk