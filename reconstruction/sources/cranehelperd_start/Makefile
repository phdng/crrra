TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# /usr/local/bin/cranehelperd_start. Referenced by CraneSB's
# `_cranehelperd_start` (0x14894) as the way to (re)start the daemon.
PROGRAM_NAME = cranehelperd_start

include $(THEOS)/makefiles/common.mk

cranehelperd_start_FILES  = cranehelperd_start.m
cranehelperd_start_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
cranehelperd_start_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/program.mk