TARGET = iphone:clang:16.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Zalo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZaloWatchAlert

ZaloWatchAlert_FILES = Tweak.x
ZaloWatchAlert_FRAMEWORKS = UIKit UserNotifications CallKit
ZaloWatchAlert_CFLAGS = -fobjc-arc

# build.sh debug -> ZALOWATCHALERT_DEBUG=1: NSLog + log file in tmp.
ifeq ($(ZALOWATCHALERT_DEBUG),1)
ZaloWatchAlert_CFLAGS += -DZWA_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
