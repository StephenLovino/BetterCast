#if canImport(UIKit)
import UIKit
import Network

class ViewController: UIViewController, NetworkListenerDelegate, InputDelegate {

    private var renderer: VideoRendererViewIOS!
    private var settingsOverlay: UIView!

    private var videoDecoder: VideoDecoder?
    private var networkListener: NetworkListenerIOS?

    // Onboarding
    private var onboardingView: UIView!
    private var statusLabel: UILabel!
    private var pulseView: UIView!
    private var isConnected = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 1. Setup Renderer
        renderer = VideoRendererViewIOS(frame: view.bounds)
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        renderer.inputDelegate = self
        view.addSubview(renderer)

        // 2. Setup Onboarding Screen
        setupOnboarding()

        // 3. Setup Settings Button & Overlay
        setupSettingsButton()
        setupSettingsOverlay()
        setupShowSettingsGesture()

        // 4. Setup Core Logic
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

        // Listen for orientation changes to update sender's virtual display
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Screen Info (command 777)

    /// Send screen dimensions to the sender so it can match the device's aspect ratio
    func sendScreenInfo() {
        let screen = UIScreen.main
        let bounds = screen.bounds
        let scale = screen.nativeScale
        // Native pixel dimensions in current orientation
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        LogManager.shared.log("ViewController: Sending screen info \(width)x\(height)")
        let event = InputEvent(type: .command, keyCode: 777, deltaX: Double(width), deltaY: Double(height))
        networkListener?.sendInputEvent(event)
    }

    @objc private func orientationChanged() {
        let orientation = UIDevice.current.orientation
        // Only respond to flat orientations that change the layout
        guard orientation == .portrait || orientation == .landscapeLeft || orientation == .landscapeRight || orientation == .portraitUpsideDown else { return }
        // Small delay to let UIKit update bounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendScreenInfo()
        }
    }

    // MARK: - Onboarding

    private func setupOnboarding() {
        onboardingView = UIView()
        onboardingView.backgroundColor = .black
        onboardingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(onboardingView)

        NSLayoutConstraint.activate([
            onboardingView.topAnchor.constraint(equalTo: view.topAnchor),
            onboardingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            onboardingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            onboardingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // App icon
        let iconView = UIImageView()
        if let appIcon = UIImage(named: "AppIcon") {
            iconView.image = appIcon
        } else {
            // Fallback: use a system symbol
            let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)
            iconView.image = UIImage(systemName: "display.2", withConfiguration: config)
            iconView.tintColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        }
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 22
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = UILabel()
        titleLabel.text = "BetterCast"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = "Display Receiver"
        subtitleLabel.textColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Divider
        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Instructions
        let instructionsLabel = UILabel()
        instructionsLabel.numberOfLines = 0
        instructionsLabel.textAlignment = .left
        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 14

        let bodyFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let dimColor = UIColor.white.withAlphaComponent(0.55)
        let brightColor = UIColor.white.withAlphaComponent(0.9)

        let instructions = NSMutableAttributedString()

        let stepAttrs: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: brightColor,
            .paragraphStyle: paragraphStyle
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: dimColor,
            .paragraphStyle: paragraphStyle
        ]

        instructions.append(NSAttributedString(string: "1. Install BetterCast Sender\n", attributes: stepAttrs))
        instructions.append(NSAttributedString(string: "Download BetterCast Sender on your Mac to extend or mirror your display to this device.\n\n", attributes: bodyAttrs))

        instructions.append(NSAttributedString(string: "2. Connect to the same network\n", attributes: stepAttrs))
        instructions.append(NSAttributedString(string: "Make sure this device and your Mac are on the same Wi-Fi network.\n\n", attributes: bodyAttrs))

        instructions.append(NSAttributedString(string: "3. Start streaming\n", attributes: stepAttrs))
        instructions.append(NSAttributedString(string: "Open BetterCast Sender and select this device. Your Mac display will appear here.", attributes: bodyAttrs))

        instructionsLabel.attributedText = instructions

        // Download link button
        let downloadButton = UIButton(type: .system)
        downloadButton.setTitle("Download at bettercast.online", for: .normal)
        downloadButton.setTitleColor(UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0), for: .normal)
        downloadButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        downloadButton.contentHorizontalAlignment = .left
        downloadButton.addTarget(self, action: #selector(openDownloadLink), for: .touchUpInside)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false

        // Pulsing dot + status
        let statusRow = UIView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        pulseView = UIView()
        pulseView.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        pulseView.layer.cornerRadius = 5
        pulseView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = UILabel()
        statusLabel.text = "Initializing..."
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusRow.addSubview(pulseView)
        statusRow.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            pulseView.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            pulseView.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            pulseView.widthAnchor.constraint(equalToConstant: 10),
            pulseView.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: pulseView.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Container stack
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        onboardingView.addSubview(contentView)

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(divider)
        contentView.addSubview(instructionsLabel)
        contentView.addSubview(downloadButton)
        contentView.addSubview(statusRow)

        if #available(iOS 11.0, *) {
            NSLayoutConstraint.activate([
                contentView.centerYAnchor.constraint(equalTo: onboardingView.centerYAnchor, constant: -20),
                contentView.leadingAnchor.constraint(equalTo: onboardingView.safeAreaLayoutGuide.leadingAnchor, constant: 40),
                contentView.trailingAnchor.constraint(equalTo: onboardingView.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            ])
        } else {
            NSLayoutConstraint.activate([
                contentView.centerYAnchor.constraint(equalTo: onboardingView.centerYAnchor, constant: -20),
                contentView.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor, constant: 40),
                contentView.trailingAnchor.constraint(equalTo: onboardingView.trailingAnchor, constant: -40),
            ])
        }

        // Max width for readability on iPad
        let maxWidth = contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        maxWidth.priority = .defaultHigh
        maxWidth.isActive = true
        contentView.centerXAnchor.constraint(equalTo: onboardingView.centerXAnchor).isActive = true

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 88),
            iconView.heightAnchor.constraint(equalToConstant: 88),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            divider.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            instructionsLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 24),
            instructionsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            instructionsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            downloadButton.topAnchor.constraint(equalTo: instructionsLabel.bottomAnchor, constant: 16),
            downloadButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            downloadButton.heightAnchor.constraint(equalToConstant: 30),

            statusRow.topAnchor.constraint(equalTo: downloadButton.bottomAnchor, constant: 20),
            statusRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Start pulse animation
        startPulseAnimation()
    }

    private func startPulseAnimation() {
        UIView.animate(withDuration: 1.2, delay: 0, options: [.repeat, .autoreverse, .curveEaseInOut]) {
            self.pulseView.alpha = 0.2
        }
    }

    private func dismissOnboarding() {
        guard !isConnected else { return }
        isConnected = true

        UIView.animate(withDuration: 0.5, delay: 0.3, options: .curveEaseOut) {
            self.onboardingView.alpha = 0
        } completion: { _ in
            self.onboardingView.isHidden = true
        }
    }

    @objc private func openDownloadLink() {
        if let url = URL(string: "https://bettercast.online/#install") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Settings Button & Overlay

    private var settingsButton: UIButton!
    private var inputModeButton: UIButton!
    private var displayModeButton: UIButton!

    private var settingsButtonBlur: UIVisualEffectView!

    private func setupSettingsButton() {
        // Blur background for the settings button
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        settingsButtonBlur = UIVisualEffectView(effect: blurEffect)
        settingsButtonBlur.layer.cornerRadius = 20
        settingsButtonBlur.clipsToBounds = true
        settingsButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButtonBlur)

        settingsButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        settingsButton.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        settingsButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        settingsButton.addTarget(self, action: #selector(settingsButtonTapped), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButtonBlur.contentView.addSubview(settingsButton)

        if #available(iOS 11.0, *) {
            NSLayoutConstraint.activate([
                settingsButtonBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                settingsButtonBlur.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                settingsButtonBlur.widthAnchor.constraint(equalToConstant: 40),
                settingsButtonBlur.heightAnchor.constraint(equalToConstant: 40),
            ])
        } else {
            NSLayoutConstraint.activate([
                settingsButtonBlur.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
                settingsButtonBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                settingsButtonBlur.widthAnchor.constraint(equalToConstant: 40),
                settingsButtonBlur.heightAnchor.constraint(equalToConstant: 40),
            ])
        }
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: settingsButtonBlur.contentView.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: settingsButtonBlur.contentView.bottomAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: settingsButtonBlur.contentView.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: settingsButtonBlur.contentView.trailingAnchor),
        ])
    }

    @objc private func settingsButtonTapped() {
        toggleSettings()
    }

    private var settingsOverlayBlur: UIVisualEffectView!

    private func setupSettingsOverlay() {
        // Use blur effect instead of solid black
        let blurEffect = UIBlurEffect(style: .systemThinMaterialDark)
        settingsOverlayBlur = UIVisualEffectView(effect: blurEffect)
        settingsOverlayBlur.layer.cornerRadius = 16
        settingsOverlayBlur.clipsToBounds = true
        settingsOverlayBlur.isHidden = true
        settingsOverlayBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsOverlayBlur)

        // Keep settingsOverlay pointing to the blur view for hide/show logic
        settingsOverlay = settingsOverlayBlur

        // Input mode button
        inputModeButton = UIButton(type: .system)
        inputModeButton.setTitle("Touch Mode", for: .normal)
        inputModeButton.setTitleColor(.white, for: .normal)
        inputModeButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.5)
        inputModeButton.layer.cornerRadius = 10
        inputModeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        inputModeButton.addTarget(self, action: #selector(toggleInputMode), for: .touchUpInside)
        inputModeButton.translatesAutoresizingMaskIntoConstraints = false

        // Display mode button
        displayModeButton = UIButton(type: .system)
        displayModeButton.setTitle("Fill Screen", for: .normal)
        displayModeButton.setTitleColor(.white, for: .normal)
        displayModeButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.5)
        displayModeButton.layer.cornerRadius = 10
        displayModeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        displayModeButton.addTarget(self, action: #selector(toggleDisplayMode), for: .touchUpInside)
        displayModeButton.translatesAutoresizingMaskIntoConstraints = false

        // Hide button option
        let hideButtonButton = UIButton(type: .system)
        hideButtonButton.setTitle("Hide Settings Button", for: .normal)
        hideButtonButton.setTitleColor(.white, for: .normal)
        hideButtonButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.5)
        hideButtonButton.layer.cornerRadius = 10
        hideButtonButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        hideButtonButton.addTarget(self, action: #selector(hideSettingsButton), for: .touchUpInside)
        hideButtonButton.translatesAutoresizingMaskIntoConstraints = false

        // Close button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.addTarget(self, action: #selector(hideSettings), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [inputModeButton, displayModeButton, hideButtonButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlayBlur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            settingsOverlayBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsOverlayBlur.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            settingsOverlayBlur.widthAnchor.constraint(equalToConstant: 220),

            stack.topAnchor.constraint(equalTo: settingsOverlayBlur.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: settingsOverlayBlur.contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: settingsOverlayBlur.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: settingsOverlayBlur.contentView.trailingAnchor, constant: -20),

            inputModeButton.heightAnchor.constraint(equalToConstant: 44),
            displayModeButton.heightAnchor.constraint(equalToConstant: 44),
            hideButtonButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func setupShowSettingsGesture() {
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(showSettingsButton))
        threeFingerTap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(threeFingerTap)
    }

    @objc private func hideSettingsButton() {
        settingsOverlay.isHidden = true
        UIView.animate(withDuration: 0.3) {
            self.settingsButtonBlur.alpha = 0
        } completion: { _ in
            self.settingsButtonBlur.isHidden = true
        }
    }

    @objc private func showSettingsButton() {
        settingsButtonBlur.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.settingsButtonBlur.alpha = 1
        }
    }

    private func toggleSettings() {
        let willShow = settingsOverlay.isHidden
        if willShow {
            settingsOverlay.isHidden = false
            settingsOverlay.alpha = 0
            UIView.animate(withDuration: 0.25) {
                self.settingsOverlay.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.2) {
                self.settingsOverlay.alpha = 0
            } completion: { _ in
                self.settingsOverlay.isHidden = true
            }
        }
    }

    @objc private func hideSettings() {
        UIView.animate(withDuration: 0.2) {
            self.settingsOverlay.alpha = 0
        } completion: { _ in
            self.settingsOverlay.isHidden = true
        }
    }

    @objc private func toggleInputMode() {
        if renderer.inputMode == .touch {
            renderer.inputMode = .cursor
            inputModeButton.setTitle("Cursor Mode", for: .normal)
        } else {
            renderer.inputMode = .touch
            inputModeButton.setTitle("Touch Mode", for: .normal)
        }
    }

    @objc private func toggleDisplayMode() {
        renderer.isAspectFill.toggle()
        displayModeButton.setTitle(renderer.isAspectFill ? "Fill Screen" : "Fit Screen", for: .normal)
    }
    
    // MARK: - NetworkListenerDelegate
    
    func networkListener(_ listener: NetworkListenerIOS, didUpdateStatus status: String) {
        if status.contains("Connected") {
            statusLabel.text = status
            // Stop pulse, show green dot, then dismiss onboarding
            pulseView.layer.removeAllAnimations()
            pulseView.alpha = 1.0
            pulseView.backgroundColor = UIColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)
            statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            dismissOnboarding()
            // Tell sender our screen dimensions so it can match our aspect ratio
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendScreenInfo()
            }
        } else if status.contains("Waiting") || status.contains("Ready") {
            statusLabel.text = status
            if !isConnected {
                pulseView.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
                startPulseAnimation()
            }
        } else if status.contains("Failed") {
            // Network listener failed (e.g. simulator or network permission denied)
            statusLabel.text = "Waiting for network access..."
            pulseView.backgroundColor = UIColor.systemOrange
            pulseView.layer.removeAllAnimations()
            pulseView.alpha = 1.0
        } else {
            statusLabel.text = status
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

