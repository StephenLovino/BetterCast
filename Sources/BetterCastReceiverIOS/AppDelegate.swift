#if canImport(UIKit)
import UIKit
import AVFoundation

// @UIApplicationMain removed -> handled in main.swift
// Window creation lives in SceneDelegate — required by the iOS 26 SDK.
class AppDelegate: UIResponder, UIApplicationDelegate {

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

        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// Root screen for a fresh window: onboarding on first run, receiver UI afterwards.
    static func makeRootViewController() -> UIViewController {
        // Screenshot automation: jump straight to a tab, skipping onboarding.
        let presetTab = UserDefaults.standard.integer(forKey: "screenshot_force_tab")
        if presetTab > 0 {
            let tabBar = BCTabBarController()
            tabBar.selectedIndex = presetTab - 1  // 1=Connect, 2=Setup, 3=Settings
            LogManager.shared.log("AppDelegate: launched with forced tab \(presetTab)")
            return tabBar
        }

        if UserDefaults.standard.bool(forKey: OnboardingHostingController.completionKey) {
            return BCTabBarController()
        }
        LogManager.shared.log("AppDelegate: first run — showing onboarding")
        return OnboardingHostingController(onComplete: { AppDelegate.swapToReceiver() })
    }

    /// Cross-dissolve the active window from onboarding to the receiver UI.
    private static func swapToReceiver() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0.delegate as? SceneDelegate)?.window }
            .first
        guard let window = window else { return }

        UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve, animations: {
            window.rootViewController = BCTabBarController()
        })
    }
}
#endif
