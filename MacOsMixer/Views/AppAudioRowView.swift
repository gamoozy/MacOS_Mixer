import SwiftUI

/// A single row in the mixer panel representing one audio-producing application.
struct AppAudioRowView: View {
    let app: AudioApp
    let outputDevices: [OutputDevice]
    let defaultOutputUID: String?

    var onVolumeChange: (Float) -> Void
    var onDeviceChange: (String?) -> Void
    var onReset: () -> Void

    @State private var localVolume: Float
    @State private var isDragging = false

    init(
        app: AudioApp,
        outputDevices: [OutputDevice],
        defaultOutputUID: String?,
        onVolumeChange: @escaping (Float) -> Void,
        onDeviceChange: @escaping (String?) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.app = app
        self.outputDevices = outputDevices
        self.defaultOutputUID = defaultOutputUID
        self.onVolumeChange = onVolumeChange
        self.onDeviceChange = onDeviceChange
        self.onReset = onReset
        self._localVolume = State(initialValue: app.volume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                appIcon
                Text(app.name)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if app.isControlled {
                    controlledBadge
                }
                volumeLabel
            }

            HStack(spacing: 8) {
                Image(systemName: localVolume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $localVolume, in: 0...1, step: 0.01) { editing in
                    isDragging = editing
                    if !editing {
                        onVolumeChange(localVolume)
                    }
                }
                .controlSize(.small)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { app.outputDeviceUID ?? "" },
                    set: { newValue in
                        onDeviceChange(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()

                Spacer()

                if app.isControlled {
                    Button(action: {
                        localVolume = 1.0
                        onReset()
                    }) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to default")
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: localVolume) { _, newValue in
            onVolumeChange(newValue)
        }
        .onChange(of: app.volume) { _, newValue in
            if !isDragging, abs(localVolume - newValue) > 0.01 {
                localVolume = newValue
            }
        }
    }

    // MARK: - Subviews

    private var appIcon: some View {
        Group {
            if let nsImage = app.icon {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var volumeLabel: some View {
        Text("\(Int(localVolume * 100))%")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
    }

    private var controlledBadge: some View {
        Circle()
            .fill(.blue)
            .frame(width: 6, height: 6)
            .help("Volume or routing is being controlled")
    }
}
