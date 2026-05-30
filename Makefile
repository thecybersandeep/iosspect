# Theos root makefile. Builds two subprojects in order:
#   IOSspect      the SwiftUI .app users see on the home screen
#   IOSspectd     the on-device HTTPS daemon that serves the dashboard
#
# Run inside the theos/theos Docker image. CI does this automatically.
# Local build:
#   docker run --rm -v "$PWD":/work -w /work theoiosjailed/theos make package FINALPACKAGE=1

export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64

# Pick the install scheme based on the env var THEOS_PACKAGE_SCHEME.
# Empty       -> rootful (paths under /)
# rootless    -> /var/jb prefix, signed with rootless entitlements
# roothide    -> hidden rootful (palera1n hidden install)
export THEOS_PACKAGE_SCHEME ?=

# Disable arm64e for now. Modern jailbreaks build arm64 fat libraries that
# load on both A12+ and pre-A12 devices.
SDKVERSION := 15.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS := IOSspect IOSspectd

include $(THEOS_MAKE_PATH)/aggregate.mk

# Run after `make package`. Installs the deb on a tethered device over SSH.
# Override DEVICE_IP + DEVICE_PASSWORD in the environment to use it.
after-install::
	install.exec "killall -9 IOSspect 2>/dev/null; killall -9 iosspectd 2>/dev/null; true"
