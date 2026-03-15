#if canImport(UIKit)
import UIKit
import Network

class ViewController: UIViewController, NetworkListenerDelegate, InputDelegate {
    
    private var renderer: VideoRendererViewIOS!
    private var statusLabel: UILabel!
    
    private var videoDecoder: VideoDecoder?
    private var networkListener: NetworkListenerIOS?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // 1. Setup Renderer
        renderer = VideoRendererViewIOS(frame: view.bounds)
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        renderer.inputDelegate = self
        view.addSubview(renderer)
        
        // 2. Setup Status Label
        statusLabel = UILabel()
        statusLabel.text = "Initializing..."
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        // iOS 11+ safe area, fallback to view edges for older iOS
        if #available(iOS 11.0, *) {
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)
            ])
        } else {
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
                statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
            ])
        }
        
        // 3. Setup Core Logic
        let decoder = VideoDecoder()
        let listener = NetworkListenerIOS()
        
        self.videoDecoder = decoder
        self.networkListener = listener
        
        listener.delegate = self
        listener.setup(decoder: decoder, renderer: renderer)
        
        // Start
        listener.start()
        
        // Prevent Sleep
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    // MARK: - NetworkListenerDelegate
    
    func networkListener(_ listener: NetworkListenerIOS, didUpdateStatus status: String) {
        // Fade out label if connected (simple logic)
        statusLabel.text = status
        statusLabel.isHidden = false
        
        if status.contains("Connected") {
            // Hide after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                UIView.animate(withDuration: 0.5) {
                    self.statusLabel.alpha = 0
                }
            }
        } else {
            self.statusLabel.alpha = 1.0
        }
    }
    
    func networkListener(_ listener: NetworkListenerIOS, didReceiveInput event: InputEvent) {
        // Receiver doesn't handle input from sender usually, but protocol demands conformance
    }
    
    // MARK: - InputDelegate
    
    func didTriggerInput(_ event: InputEvent) {
        networkListener?.sendInputEvent(event)
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    @available(iOS 11.0, *)
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
}
#endif

