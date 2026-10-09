TARGET := iphone:clang:latest
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# The original dylib is installed with a LEADING SPACE in its name. Theos
# derives the output file name from TWEAK_NAME, so the space is embedded here
# and the master Makefile's package-stage rule copies it into place verbatim.
TWEAK_NAME =  Crane

include $(THEOS)/makefiles/common.mk

Crane_FILES  = CRMainDylib.m
Crane_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
Crane_FRAMEWORKS = Foundation CoreFoundation LocalAuthentication
Crane_LIBRARIES  = objc

include $(THEOS_MAKE_PATH)/tweak.mk