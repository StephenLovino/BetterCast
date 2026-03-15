import Foundation

#if canImport(UIKit)
import UIKit

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)

#else

print("BetterCastReceiverIOS is intended for iOS devices only.")
print("Please select an iOS Simulator or Device in Xcode to run this target.")

#endif
