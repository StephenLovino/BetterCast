import Foundation

/// Slim logger for the legacy receiver. The main app's LogManager.swift also carries the
/// in-app update checker / changelog / log view (all macOS-13 SwiftUI), which we don't want
/// here — the shared receiver core only ever calls `LogManager.shared.log(_:)`, so this
/// provides exactly that interface.
final class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published private(set) var logs: [String] = []

    func log(_ message: String) {
        print("[BetterCast] \(message)")
        DispatchQueue.main.async {
            self.logs.append(message)
            if self.logs.count > 500 { self.logs.removeFirst(self.logs.count - 500) }
        }
    }
}
