TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# CraneSB.dylib. Substrate filter (CONFIRMED_STATIC from CraneSB.plist):
#   Bundles = [com.apple.springboard], Executables = [runningboardd]
TWEAK_NAME = CraneSB
INSTALL_TARGET_PROCESSES = SpringBoard, runningboardd

include $(THEOS)/makefiles/common.mk

CraneSB_FILES  = CRSpringBoard.m ../common/CRCommon.m
CraneSB_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
CraneSB_FRAMEWORKS = Foundation CoreFoundation UIKit LocalAuthentication
CraneSB_FRAMEWORKS += BackBoardServices AppSupport MobileCoreServices
CraneSB_LIBRARIES  = objc libcrane.dylib

include $(THEOS_MAKE_PATH)/tweak.mk