#if canImport(UIKit)
import UIKit

/// Root tab bar for the receiver app: Connect / Setup / Settings.
///
/// Replaces the previous custom SwiftUI BottomNavBar + horizontal-slide modal
/// stack. As a native `UITabBarController` it gives us a persistent tab bar
/// that doesn't animate with the content (fixing the "flipping book" effect
/// when switching screens), and on iOS 26 it automatically picks up the
/// Liquid Glass material without any custom material code.
@available(iOS 15.0, *)
final class BCTabBarController: UITabBarController {

    let connectVC: ViewController
    let setupVC: SetupGuideHostingController
    let settingsVC: SettingsHostingController

    init() {
        let connect = ViewController()

        let setup = SetupGuideHostingController()
        let settings = SettingsHostingController(connect: connect)

        self.connectVC = connect
        self.setupVC = setup
        self.settingsVC = settings

        super.init(nibName: nil, bundle: nil)

        connect.tabBarItem = UITabBarItem(
            title: "Connect",
            image: UIImage(systemName: "play.display"),
            tag: 0
        )
        setup.tabBarItem = UITabBarItem(
            title: "Setup",
            image: UIImage(systemName: "questionmark.circle"),
            tag: 1
        )
        settings.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "slider.horizontal.3"),
            tag: 2
        )

        viewControllers = [connect, setup, settings]
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTabBarAppearance()
        delegate = self
        // SCREENSHOT: force Setup tab
        selectedIndex = 1
        print("BCTabBarController.viewDidLoad: selectedIndex = \(selectedIndex)")
    }

    /// Transparent appearance — on iOS 26 the system layers Liquid Glass under
    /// the bar automatically; on iOS 15-18 it shows the system blur material.
    private func applyTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    /// Called by ViewController when streaming starts/stops. When streaming we
    /// hide the tab bar so the mirror surface is unobstructed.
    func setTabBarVisible(_ visible: Bool, animated: Bool) {
        guard tabBar.isHidden == visible else { return }
        let work = { self.tabBar.isHidden = !visible }
        if animated {
            UIView.transition(with: tabBar, duration: 0.25, options: .transitionCrossDissolve, animations: work)
        } else {
            work()
        }
    }
}

@available(iOS 15.0, *)
extension BCTabBarController: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        // Pull fresh state from Connect into Settings/Setup each time they're
        // surfaced — the in-stream gear overlay can mutate the same state, so
        // these tabs need to refresh on appear.
        if let s = viewController as? SettingsHostingController {
            s.refreshFromConnect()
        }

        // No automatic hide/show on tab switch — the user controls tab bar
        // visibility explicitly via the 3-finger reveal gesture and the
        // "Hide Navigation" / "Show Navigation" menu toggle.
    }
}
#endif
