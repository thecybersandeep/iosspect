// main.swift - explicit C entry point.
//
// Avoid @UIApplicationMain / @main on AppDelegate: Theos synthesises
// its own main.swift, which conflicts. Hand-rolling the call is the
// safe pattern for any UIKit-on-Theos project.

import UIKit

_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
