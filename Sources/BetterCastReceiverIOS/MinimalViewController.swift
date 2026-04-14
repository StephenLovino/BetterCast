#if canImport(UIKit)
import UIKit

// Minimal test version - NO networking, NO video decoding
class MinimalViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Simple label with iOS 12 warning
        let label = UILabel()
        label.text = "BetterCast Receiver\\n\\n⚠️ iOS 12 Not Supported\\n\\nNetwork.framework crashes on iOS 12.5.7\\n\\nMinimum: iOS 13.0\\nRecommended: iOS 14+\\n\\niPhone 6 max: iOS 12.5.7"
        label.textColor = .orange
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
        
        LogManager.shared.log("MinimalViewController loaded — basic UI works")
    }
}
#endif
