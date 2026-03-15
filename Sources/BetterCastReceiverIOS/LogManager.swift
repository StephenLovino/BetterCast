#if canImport(UIKit)
import Foundation

class LogManager {
    static let shared = LogManager()
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] \(message)")
    }
}
#endif

