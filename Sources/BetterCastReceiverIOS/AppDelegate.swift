#if canImport(UIKit)
import UIKit
import AVFoundation

// @UIApplicationMain removed -> handled in main.swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.log("AppDelegate: launching on iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))")

        // Required: configure audio session before AVSampleBufferDisplayLayer works on iOS.
        // Without this, FigApplicationStateMonitor throws errors and frames don't render.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            LogManager.shared.log("AppDelegate: audio session configured")
        } catch {
            LogManager.shared.log("AppDelegate: audio session setup failed — \(error)")
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()

        return true
    }
}
#endif
