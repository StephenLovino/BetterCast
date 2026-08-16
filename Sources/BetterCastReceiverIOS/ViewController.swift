#if canImport(UIKit)
import UIKit
import Network

/// UIButton subclass that holds a reference to the discovered sender it represents,
/// so the action handler can connect to it without needing tag-based lookups.
private class SenderButton: UIButton {
    var sender: DiscoveredSender?
    convenience init(sender: DiscoveredSender, type: UIButton.ButtonType) {
        self.init(type: type)
        self.sender = sender
    }
}

// Receiver screen (tab-bar shell, SF Symbols, UIMenu/UIDeferredMenuElement).
class ViewController: UIViewController, NetworkListenerDelegate, InputDelegate {

    private var renderer: VideoRendererViewIOS!

    private var videoDecoder: VideoDecoder?
    private var networkListener: NetworkListenerIOS?

    // Onboarding
    private var onboardingView: UIView!
    private var statusLabel: UILabel!
    private var pulseView: UIView!
    private var deviceNameField: UITextField!
    private var isConnected = false

    // "Connect to Mac" section — shown when senders are discovered via Bonjour
    private var sendersHeader: UILabel!
    private var sendersStack: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Connect screen is a video surface — pin it dark regardless of system theme.
        overrideUserInterfaceStyle = .dark

        // 1. Setup Renderer
        renderer = VideoRendererViewIOS(frame: view.bounds)
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        renderer.inputDelegate = self
        view.addSubview(renderer)

        // 2. Setup Onboarding Screen
        setupOnboarding()

        // 3. Setup Settings Button (with attached UIMenu) + reveal gesture
        setupSettingsButton()
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

        // Device name field
        let nameContainer = UIView()
        nameContainer.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = UILabel()
        nameLabel.text = "Device Name"
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceNameField = UITextField()
        let savedName = UserDefaults.standard.string(forKey: "customDeviceName")
        deviceNameField.text = savedName ?? UIDevice.current.name
        deviceNameField.textColor = .white
        deviceNameField.font = .systemFont(ofSize: 16, weight: .medium)
        deviceNameField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        deviceNameField.layer.cornerRadius = 10
        deviceNameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        deviceNameField.leftViewMode = .always
        deviceNameField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        deviceNameField.rightViewMode = .always
        deviceNameField.returnKeyType = .done
        deviceNameField.attributedPlaceholder = NSAttributedString(
            string: "e.g. Stephen's iPhone",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.25)]
        )
        deviceNameField.addTarget(self, action: #selector(deviceNameChanged), for: .editingDidEnd)
        deviceNameField.addTarget(self, action: #selector(deviceNameReturnPressed), for: .editingDidEndOnExit)
        deviceNameField.translatesAutoresizingMaskIntoConstraints = false

        nameContainer.addSubview(nameLabel)
        nameContainer.addSubview(deviceNameField)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: nameContainer.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),

            deviceNameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            deviceNameField.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor),
            deviceNameField.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor),
            deviceNameField.heightAnchor.constraint(equalToConstant: 40),
            deviceNameField.bottomAnchor.constraint(equalTo: nameContainer.bottomAnchor),
        ])

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

        // "Connect to Mac" section — populated as Bonjour discovers BetterCast Senders
        sendersHeader = UILabel()
        sendersHeader.text = "Available Senders"
        sendersHeader.textColor = brightColor
        sendersHeader.font = boldFont
        sendersHeader.translatesAutoresizingMaskIntoConstraints = false

        sendersStack = UIStackView()
        sendersStack.axis = .vertical
        sendersStack.spacing = 8
        sendersStack.translatesAutoresizingMaskIntoConstraints = false

        // Initial placeholder — replaced when senders are discovered
        let placeholder = UILabel()
        placeholder.text = "Searching..."
        placeholder.textColor = dimColor
        placeholder.font = bodyFont
        sendersStack.addArrangedSubview(placeholder)

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

        // Scroll view wraps contentView so it never overlaps the bottom nav even if content is tall
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        // Bottom inset = nav bar height (88pt) so content can scroll fully into view above the nav
        scrollView.contentInset = UIEdgeInsets(top: 24, left: 0, bottom: 96, right: 0)
        onboardingView.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(nameContainer)
        contentView.addSubview(divider)
        contentView.addSubview(instructionsLabel)
        contentView.addSubview(downloadButton)
        contentView.addSubview(sendersHeader)
        contentView.addSubview(sendersStack)
        contentView.addSubview(statusRow)

        if #available(iOS 11.0, *) {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: onboardingView.safeAreaLayoutGuide.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: onboardingView.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: onboardingView.trailingAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: onboardingView.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: onboardingView.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: onboardingView.trailingAnchor),
            ])
        }

        let contentWidth = contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -80)
        contentWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentWidth,
        ])

        // Max width for readability on iPad
        contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

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

            nameContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            nameContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            divider.topAnchor.constraint(equalTo: nameContainer.bottomAnchor, constant: 20),
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

            sendersHeader.topAnchor.constraint(equalTo: downloadButton.bottomAnchor, constant: 18),
            sendersHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sendersHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            sendersStack.topAnchor.constraint(equalTo: sendersHeader.bottomAnchor, constant: 8),
            sendersStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sendersStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            statusRow.topAnchor.constraint(equalTo: sendersStack.bottomAnchor, constant: 16),
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
        // Hide the tab bar so the mirror surface is unobstructed.
        if #available(iOS 15.0, *) {
            (tabBarController as? BCTabBarController)?.setTabBarVisible(false, animated: true)
        }
    }

    /// Inverse of dismissOnboarding — brings the onboarding view back so the
    /// user can pick a sender again after disconnecting.
    private func restoreOnboarding() {
        isConnected = false
        onboardingView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.onboardingView.alpha = 1
        }
        if #available(iOS 15.0, *) {
            (tabBarController as? BCTabBarController)?.setTabBarVisible(true, animated: true)
        }
        pulseView.layer.removeAllAnimations()
        pulseView.alpha = 1.0
        pulseView.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        startPulseAnimation()
        statusLabel.text = "Waiting for Sender..."
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.5)
    }

    @objc private func openDownloadLink() {
        if let url = URL(string: "https://bettercast.online/#install") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func deviceNameChanged() {
        let name = deviceNameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: "customDeviceName")
        LogManager.shared.log("ViewController: Device name changed to '\(name)' — restart app to apply")
    }

    @objc private func deviceNameReturnPressed() {
        deviceNameField.resignFirstResponder()
    }

    // MARK: - Settings Button (floating gear, opens UIMenu)

    private var settingsButton: UIButton!
    private var settingsButtonBlur: UIVisualEffectView!

    private func setupSettingsButton() {
        // System material — adapts to light/dark automatically and gets
        // Liquid Glass on iOS 26.
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        settingsButtonBlur = UIVisualEffectView(effect: blurEffect)
        settingsButtonBlur.layer.cornerRadius = 20
        settingsButtonBlur.clipsToBounds = true
        settingsButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButtonBlur)

        settingsButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        settingsButton.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        settingsButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.menu = makeSettingsMenu()
        settingsButtonBlur.contentView.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButtonBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButtonBlur.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            settingsButtonBlur.widthAnchor.constraint(equalToConstant: 40),
            settingsButtonBlur.heightAnchor.constraint(equalToConstant: 40),

            settingsButton.topAnchor.constraint(equalTo: settingsButtonBlur.contentView.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: settingsButtonBlur.contentView.bottomAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: settingsButtonBlur.contentView.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: settingsButtonBlur.contentView.trailingAnchor),
        ])
    }

    /// Builds a UIMenu whose items reflect *current* state (input mode,
    /// aspect fill, navigation visibility). `UIDeferredMenuElement.uncached`
    /// rebuilds the menu body each time the user opens it, so toggles always
    /// show the right checkmarks without manual title updates.
    private func makeSettingsMenu() -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self = self else { completion([]); return }

            let cursorOn = (self.renderer?.inputMode == .cursor)
            let inputItem = UIAction(
                title: cursorOn ? "Cursor Mode" : "Touch Mode",
                image: UIImage(systemName: cursorOn ? "cursorarrow.motionlines" : "hand.tap"),
                state: cursorOn ? .on : .off
            ) { [weak self] _ in self?.toggleInputMode() }

            let fillOn = (self.renderer?.isAspectFill ?? true)
            let displayItem = UIAction(
                title: fillOn ? "Fill Screen" : "Fit Screen",
                image: UIImage(systemName: fillOn ? "rectangle.fill" : "rectangle"),
                state: fillOn ? .on : .off
            ) { [weak self] _ in self?.toggleDisplayMode() }

            let navVisible = (self.tabBarController?.tabBar.isHidden == false)
            let navItem = UIAction(
                title: navVisible ? "Hide Navigation" : "Show Navigation",
                image: UIImage(systemName: navVisible ? "rectangle.bottomthird.inset.filled" : "rectangle"),
                state: navVisible ? .on : .off
            ) { [weak self] _ in self?.toggleNavigationBar() }

            let setupItem = UIAction(
                title: "Setup Guide",
                image: UIImage(systemName: "questionmark.circle")
            ) { [weak self] _ in self?.showSetupGuide() }

            let hideButtonItem = UIAction(
                title: "Hide Settings Button",
                image: UIImage(systemName: "eye.slash")
            ) { [weak self] _ in self?.hideSettingsButton() }

            let disconnectItem = UIAction(
                title: "Disconnect",
                image: UIImage(systemName: "xmark.circle.fill"),
                attributes: .destructive
            ) { [weak self] _ in self?.disconnectTapped() }

            let modeGroup = UIMenu(options: .displayInline, children: [inputItem, displayItem])
            let chromeGroup = UIMenu(options: .displayInline, children: [navItem, setupItem])
            let manageGroup = UIMenu(options: .displayInline, children: [hideButtonItem, disconnectItem])

            completion([modeGroup, chromeGroup, manageGroup])
        }
        return UIMenu(title: "BetterCast", children: [deferred])
    }

    @objc private func showSetupGuide() {
        // Make sure the tab bar is visible *before* switching tabs — otherwise
        // the user lands on Setup with no way to leave.
        if #available(iOS 15.0, *) {
            (tabBarController as? BCTabBarController)?.setTabBarVisible(true, animated: true)
        }
        tabBarController?.selectedIndex = 1
    }

    private func toggleNavigationBar() {
        guard #available(iOS 15.0, *), let bar = tabBarController as? BCTabBarController else { return }
        bar.setTabBarVisible(bar.tabBar.isHidden, animated: true)
    }

    @objc private func disconnectTapped() {
        networkListener?.disconnect()
        restoreOnboarding()
    }

    private func setupShowSettingsGesture() {
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(showSettingsButton))
        threeFingerTap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(threeFingerTap)
    }

    @objc private func hideSettingsButton() {
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
        // 3-finger tap is the "reveal all chrome" gesture — also bring back
        // the navigation tab bar so the user can switch tabs without going
        // through the menu.
        if #available(iOS 15.0, *) {
            (tabBarController as? BCTabBarController)?.setTabBarVisible(true, animated: true)
        }
    }

    private func toggleInputMode() {
        renderer.inputMode = (renderer.inputMode == .touch) ? .cursor : .touch
    }

    private func toggleDisplayMode() {
        renderer.isAspectFill.toggle()
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

    func networkListener(_ listener: NetworkListenerIOS, didUpdateDiscoveredSenders senders: [DiscoveredSender]) {
        guard let sendersStack = sendersStack else { return }
        // Clear and rebuild — small list, this is fine
        sendersStack.arrangedSubviews.forEach { view in
            sendersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if senders.isEmpty {
            let placeholder = UILabel()
            placeholder.text = "Searching..."
            placeholder.textColor = UIColor.white.withAlphaComponent(0.4)
            placeholder.font = .systemFont(ofSize: 14)
            sendersStack.addArrangedSubview(placeholder)
            return
        }
        for sender in senders {
            let button = SenderButton(sender: sender, type: .system)
            button.setTitle(sender.name, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            button.backgroundColor = UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 0.18)
            button.layer.cornerRadius = 10
            button.addTarget(self, action: #selector(connectToSenderTapped(_:)), for: .touchUpInside)
            sendersStack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
    }

    @objc private func connectToSenderTapped(_ sender: SenderButton) {
        guard let target = sender.sender else { return }
        LogManager.shared.log("ViewController: User tapped Connect for sender \(target.name)")
        networkListener?.connectToSender(target)
    }
    
    // MARK: - InputDelegate
    
    func didTriggerInput(_ event: InputEvent) {
        networkListener?.sendInputEvent(event)
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    // MARK: - Public state API (read/written by Settings + Setup tabs)

    var isStreaming: Bool { isConnected }

    var currentDeviceName: String {
        UserDefaults.standard.string(forKey: "customDeviceName") ?? UIDevice.current.name
    }

    var currentAspectFill: Bool {
        renderer?.isAspectFill ?? true
    }

    var currentCursorMode: Bool {
        renderer?.inputMode == .cursor
    }

    var currentAudioEnabled: Bool {
        networkListener?.audioEnabled ?? true
    }

    func commitDeviceName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "customDeviceName")
        deviceNameField?.text = name
        LogManager.shared.log("ViewController: Device name changed to '\(name)' — restart app to apply")
    }

    func applyAspectFill(_ fill: Bool) {
        renderer?.isAspectFill = fill
    }

    func applyCursorMode(_ cursor: Bool) {
        renderer?.inputMode = cursor ? .cursor : .touch
    }

    func applyAudioEnabled(_ enabled: Bool) {
        networkListener?.setAudioEnabled(enabled)
    }

    func disconnectAndRestore() {
        networkListener?.disconnect()
        restoreOnboarding()
    }

    func hideSettingsButtonFromSibling() {
        hideSettingsButton()
    }
}
#endif

