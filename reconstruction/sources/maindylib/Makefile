TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# The original dylib is installed with a LEADING SPACE in its name. GNU make
# strips assignment-leading whitespace, so the target is built as Crane.dylib
# and the master after-stage rule renames it to " Crane.dylib".
TWEAK_NAME = Crane

include $(THEOS)/makefiles/common.mk

Crane_FILES  = CRMainDylib.m ../common/CRCommon.m
Crane_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
Crane_FRAMEWORKS = Foundation CoreFoundation LocalAuthentication
Crane_LIBRARIES  = substrate

include $(THEOS_MAKE_PATH)/tweak.mk