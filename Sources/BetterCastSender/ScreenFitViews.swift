import SwiftUI

/// The resolution presets plus a "Custom..." entry with width and height fields.
/// One view for every place the resolution is picked, so they cannot drift apart.
struct ResolutionPicker: View {
    let title: LocalizedStringKey
    @ObservedObject var client: NetworkClient

    private enum Choice: Hashable {
        case preset(VirtualDisplayManager.Resolution)
        case custom
    }

    @State private var customOpen = false
    @State private var widthText = ""
    @State private var heightText = ""

    private var choice: Binding<Choice> {
        Binding(
            get: {
                customOpen || !client.selectedResolution.isPreset ? .custom : .preset(client.selectedResolution)
            },
            set: { newValue in
                switch newValue {
                case .preset(let res):
                    customOpen = false
                    client.selectedResolution = res
                case .custom:
                    widthText = String(client.selectedResolution.width)
                    heightText = String(client.selectedResolution.height)
                    customOpen = true
                }
            }
        )
    }

    private var typedSize: PixelSize? { PixelSize.parse(width: widthText, height: heightText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: choice) {
                ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                    Text(res.name).tag(Choice.preset(res))
                }
                Divider()
                Text(client.selectedResolution.isPreset ? tr("Custom...") : client.selectedResolution.name)
                    .tag(Choice.custom)
            }

            if customOpen || !client.selectedResolution.isPreset {
                SizeFields(widthText: $widthText, heightText: $heightText) {
                    Button("Set") {
                        guard let size = typedSize else { return }
                        client.selectedResolution = .custom(size)
                        customOpen = false
                    }
                    .disabled(typedSize == nil)
                }
                .onAppear {
                    if widthText.isEmpty {
                        widthText = String(client.selectedResolution.width)
                        heightText = String(client.selectedResolution.height)
                    }
                }
                Text("Width and height in pixels, 640 to 5120. Match the receiver's screen to remove black bars. While connected, click Apply Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Two small number fields for a width and a height, plus trailing buttons.
private struct SizeFields<Trailing: View>: View {
    @Binding var widthText: String
    @Binding var heightText: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            TextField("Width", text: $widthText).frame(width: 64)
            Text("x")
            TextField("Height", text: $heightText).frame(width: 64)
            trailing()
        }
        .textFieldStyle(.roundedBorder)
    }
}

/// A device's screen: its native size (reported, or registered by the user) and the text
/// size the display runs at.
struct DeviceScreenSection: View {
    let serviceName: String
    @ObservedObject var client: NetworkClient

    @State private var editing = false
    @State private var widthText = ""
    @State private var heightText = ""

    private var typedSize: PixelSize? { PixelSize.parse(width: widthText, height: heightText) }

    var body: some View {
        // Read so this view redraws when any device's screen preferences change.
        let _ = client.screenPrefsRevision

        Section("Screen") {
            if let reported = client.reportedNativeSize(for: serviceName) {
                LabeledContent("Native Resolution", value: reported.label)
                Text("Reported by the device, and followed when it rotates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let registered = client.registeredNativeSize(for: serviceName), !editing {
                LabeledContent("Native Resolution") {
                    HStack(spacing: 8) {
                        Text(registered.label)
                        Button("Change") {
                            widthText = String(registered.width)
                            heightText = String(registered.height)
                            editing = true
                        }
                        Button("Remove") { client.setRegisteredNativeSize(nil, for: serviceName) }
                    }
                }
                HStack {
                    Toggle("Portrait", isOn: Binding(
                        get: { registered.isPortrait },
                        set: { wantPortrait in
                            guard wantPortrait != registered.isPortrait else { return }
                            client.setRegisteredNativeSize(registered.rotated, for: serviceName)
                        }
                    ))
                    InfoTip(text: "Stand the display upright for a device used in portrait. Devices that report their own size follow their rotation automatically.")
                }
            } else {
                LabeledContent("Native Resolution") {
                    SizeFields(widthText: $widthText, heightText: $heightText) {
                        Button("Save") {
                            guard let size = typedSize else { return }
                            client.setRegisteredNativeSize(size, for: serviceName)
                            editing = false
                        }
                        .disabled(typedSize == nil)
                        if editing {
                            Button("Cancel") { editing = false }
                        }
                    }
                }
                Text("This device does not report its screen size. Enter it in pixels (for example 2160 x 1584) to stream at full sharpness with no black bars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            textSizeRow
        }
    }

    @ViewBuilder
    private var textSizeRow: some View {
        let options = client.textSizeOptions(for: serviceName)
        if !options.isEmpty, let selected = client.selectedTextSize(for: serviceName) {
            HStack {
                Picker("Text Size", selection: Binding(
                    get: { selected },
                    set: { client.setTextSize($0, for: serviceName) }
                )) {
                    ForEach(Array(options.enumerated()), id: \.element) { index, option in
                        Text(label(option, index: index, count: options.count)).tag(option)
                    }
                }
                InfoTip(text: "How large the desktop looks on this device. The stream stays at the native resolution, so every size is sharp. Also adjustable in System Settings > Displays.")
            }
        } else if client.nativeSize(for: serviceName) != nil && !client.isRetina {
            Text("Turn on Retina (HiDPI) to choose a text size for this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ option: TextSizeOption, index: Int, count: Int) -> String {
        let size = option.points.label
        if option.pixelsPerPoint == TextSizing.defaultPixelsPerPoint { return "\(size) (\(tr("Default")))" }
        if index == 0 { return "\(size) (\(tr("Larger Text")))" }
        if index == count - 1 { return "\(size) (\(tr("More Space")))" }
        return size
    }
}
