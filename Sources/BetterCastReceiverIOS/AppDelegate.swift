#if canImport(UIKit)
import UIKit

// @UIApplicationMain removed -> handled in main.swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("[BetterCast] AppDelegate: didFinishLaunchingWithOptions called")
        print("[BetterCast] iOS Version: \(UIDevice.current.systemVersion)")
        print("[BetterCast] Device Model: \(UIDevice.current.model)")
        
        do {
            window = UIWindow(frame: UIScreen.main.bounds)
            print("[BetterCast] Window created successfully")
            
            // Use full ViewController (not minimal test)
            window?.rootViewController = ViewController()
            print("[BetterCast] ViewController created successfully")
            
            window?.makeKeyAndVisible()
            print("[BetterCast] Window made key and visible")
            
            return true
        } catch {
            print("[BetterCast] CRASH in AppDelegate: \(error)")
            return false
        }
    }
}
#endif

