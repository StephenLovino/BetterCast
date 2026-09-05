import SwiftUI
import AppKit

/// Restores the window when the app icon is clicked.
///
/// The app has no reason to quit when its window closes: it may well still be driving
/// a display. But with no delegate implementing this, clicking the icon did nothing at
/// all, and the only way back was File > New Window. Almost every Mac app reopens on
/// that click, so doing nothing reads as the app being broken rather than as a choice.
final class BetterCastAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }

        // A window that is merely hidden or minimised just needs bringing forward.
        // Panels and the like are skipped so the main window is what surfaces.
        let restorable = sender.windows.filter { $0.canBecomeMain }
        if let window = restorable.first {
            window.makeKeyAndOrderFront(self)
            sender.activate(ignoringOtherApps: true)
            return false
        }

        // Nothing left to restore. Returning true asks AppKit to do its default thing,
        // which for a SwiftUI WindowGroup is to build a fresh window.
        return true
    }

    /// Closing the window is not quitting. The stream, the virtual display and the
    /// receiver listener all carry on, which is the point of a display tool.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
