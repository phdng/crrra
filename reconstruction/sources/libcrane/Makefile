TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# libcrane is loaded by CraneSB, CraneSupport, CranePrefs and the legacy
# CraneShortcuts extension. It is the client half of the cranehelperd XPC pair.
TWEAK_NAME = libcrane
INSTALL_TARGET_PROCESSES = SpringBoard runningboardd cfprefsd containermanagerd \
                            securityd pkd lsd accountsd apsd

include $(THEOS)/makefiles/common.mk

# A plain dylib, not a tweak: the original installs it at /usr/lib/libcrane.dylib
# (LC_ID_DYLIB = /usr/lib/libcrane.dylib) and it has no Substrate filter plist.
# The master Makefile moves it into /usr/lib after staging.
LIBRARY_NAME = libcrane

libcrane_FILES  = ../libcrane/CRManager.m
libcrane_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
libcrane_FRAMEWORKS = Foundation CoreFoundation
libcrane_LIBRARIES  = objc

include $(THEOS_MAKE_PATH)/library.mk