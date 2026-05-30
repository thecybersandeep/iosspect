# IOSspect - the SwiftUI dashboard the user sees when they tap the
# home-screen icon. Bundle id com.iosspect.tool.

TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = IOSspect

IOSspect_FILES = \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/SceneDelegate.swift \
    Sources/DashboardView.swift \
    Sources/ServerControl.swift \
    Sources/Settings.swift \
    Sources/CryptoUtil.swift

IOSspect_FRAMEWORKS = UIKit SwiftUI Foundation Security
IOSspect_PRIVATE_FRAMEWORKS = Preferences
IOSspect_SWIFTFLAGS = -ISources

# Copy the icon PNGs into the .app bundle. Resources/ is flat (no
# Xcode .xcassets or .storyboard, since those need actool/ibtool which
# only ship on macOS, not on the Linux CI runner).
IOSspect_BUNDLE_RESOURCE_DIRS = Resources

# Explicitly tell Theos which plist becomes the bundle's Info.plist.
# Some Theos versions skip the project-root auto-detection.
IOSspect_PLIST = Info.plist

# Entitlements injected at sign time. Required to talk to launchctl
# from inside the app sandbox on rootless jailbreaks.
IOSspect_CODESIGN_FLAGS = -Sentitlements.plist

# Install location. Both rootful and rootless paths.
IOSspect_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
