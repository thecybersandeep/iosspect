# IOSspectd - the on-device HTTPS daemon. Runs as root, owns the
# embedded HTTP server, the TLS cert, and every privileged primitive
# (file reads, sysctl, os_log_stream).

TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = iosspectd

# All Swift sources. New route files go into Sources/Server/routes/ and
# get listed here, mirroring the structure in Sources/Root/.
iosspectd_FILES = \
    Sources/main.swift \
    Sources/Server/IOSspectServer.swift \
    Sources/Server/TLSManager.swift \
    Sources/Server/Security.swift \
    Sources/Server/Router.swift \
    Sources/Server/OSVersion.swift \
    Sources/Server/routes/SystemRoutes.swift \
    Sources/Server/routes/AppRoutes.swift \
    Sources/Server/routes/FileRoutes.swift \
    Sources/Server/routes/PrefsRoutes.swift \
    Sources/Server/routes/SqliteRoutes.swift \
    Sources/Server/routes/ManifestRoutes.swift \
    Sources/Server/routes/LiveRoutes.swift \
    Sources/Server/routes/AssetRoutes.swift \
    Sources/Root/AppDataReader.swift \
    Sources/Root/FileBrowser.swift \
    Sources/Root/PlistReader.swift \
    Sources/Root/SqliteReader.swift \
    Sources/Root/NativeLibScanner.swift \
    Sources/Root/ProcessReader.swift \
    Sources/Root/NetReader.swift \
    Sources/Root/LogcatStreamer.swift \
    Sources/Root/AppActions.swift \
    Sources/Root/ShellRunner.swift \
    Sources/Root/ZipWriter.swift \
    Sources/Root/Sanitize.swift

iosspectd_FRAMEWORKS = Foundation Security UIKit
iosspectd_LIBRARIES = sqlite3 z

# The Swift toolchain that ships in theos-action handles the @objc
# bridging we need for the private MobileInstallation framework. We
# load it via dlopen at runtime to avoid linking against private SDKs.
iosspectd_SWIFTFLAGS = -ISources

iosspectd_CODESIGN_FLAGS = -Sentitlements.plist

iosspectd_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
