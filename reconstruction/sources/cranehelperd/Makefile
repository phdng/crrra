TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

# Installed at /usr/local/libexec/cranehelperd and started by launchd as root.
# Registration is reproduced from Library/LaunchDaemons/com.opa334.cranehelperd.plist:
#   Label  com.opa334.cranehelperd
#   UserName root, RunAtLoad, KeepAlive, ProcessType Interactive
#   EnvironmentVariables: _MSSafeMode=1, _SafeMode=1
#   MachServices: com.opa334.cranehelperd.xpc, com.opa334.cranehelperd.preferences.xpc
PROGRAM_NAME = cranehelperd

include $(THEOS)/makefiles/common.mk

cranehelperd_FILES  = CRHelperd.m ../common/CRCommon.m
cranehelperd_CFLAGS  = -fobjc-arc -I$(THEOS_PROJECT_DIR)/sources/common
cranehelperd_FRAMEWORKS = Foundation CoreFoundation BackBoardServices MobileCoreServices Security
cranehelperd_LIBRARIES  = objc

include $(THEOS_MAKE_PATH)/program.mk