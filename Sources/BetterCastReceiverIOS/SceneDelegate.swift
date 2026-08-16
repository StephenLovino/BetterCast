#if canImport(UIKit)
import UIKit

/// Window setup for the UIScene lifecycle.
///
/// Required as of the iOS 26 SDK: apps linked against it that still build their
/// window in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` are
/// terminated at launch. Scenes exist since iOS 13, so this costs nothing on
/// any OS version the app supports.
@available(iOS 13.0, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = AppDelegate.makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window

        LogManager.shared.log("SceneDelegate: window attached on iOS \(UIDevice.current.systemVersion)")

        // Deep links delivered at cold launch arrive here, not via openURLContexts.
        if let url = connectionOptions.urlContexts.first?.url {
            handle(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { handle(url) }
    }

    /// `bettercast://setup` / `://settings` — used by the screenshot automation
    /// to jump straight to a tab.
    private func handle(_ url: URL) {
        guard let host = url.host, #available(iOS 15.0, *),
              let tabBar = window?.rootViewController as? BCTabBarController else { return }
        switch host {
        case "setup":    tabBar.selectedIndex = 1
        case "settings": tabBar.selectedIndex = 2
        default:         tabBar.selectedIndex = 0
        }
    }
}
#endif
