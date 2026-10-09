TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e

# CraneSB.dylib. Substrate filter (CONFIRMED_STATIC from CraneSB.plist):
#   Bundles = [com.apple.springboard], Executables = [runningboardd]
TWEAK_NAME = CraneSB
INSTALL_TARGET_PROCESSES = SpringBoard runningboardd

include $(THEOS)/makefiles/common.mk

CraneSB_FILES  = CRSpringBoard.m CRActivator.m ../common/CRCommon.m
CraneSB_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CraneSB_FRAMEWORKS = Foundation CoreFoundation UIKit LocalAuthentication MobileCoreServices
# The original binary links BackBoardServices/AppSupport, but this partial
# reconstruction does not reference symbols from either framework yet. Avoid
# requiring private SDK stubs that are absent from the CI SDK.
CraneSB_LIBRARIES  = crane
CraneSB_LDFLAGS += -L$(THEOS_OBJ_DIR)

include $(THEOS_MAKE_PATH)/tweak.mk