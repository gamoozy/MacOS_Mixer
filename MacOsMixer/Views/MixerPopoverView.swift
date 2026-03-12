import SwiftUI

/// Main content view displayed in the menu-bar popover.
struct MixerPopoverView: View {
    @Environment(MixerState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !state.micPermissionGranted {
                permissionWarning
                Divider()
            }

            if state.audioApps.isEmpty {
                emptyState
            } else {
                appList
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.blue)
            Text("MacOs Mixer")
                .font(.headline)
            Spacer()
            Text("\(state.audioApps.count) app\(state.audioApps.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - App List

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.audioApps) { app in
                    AppAudioRowView(
                        app: app,
                        outputDevices: state.outputDevices,
                        defaultOutputUID: state.defaultOutputUID,
                        onVolumeChange: { volume in
                            state.setVolume(volume, for: app)
                        },
                        onDeviceChange: { uid in
                            state.setOutputDevice(uid: uid, for: app)
                        },
                        onReset: {
                            state.resetApp(app)
                        }
                    )
                    .padding(.horizontal, 16)

                    if app.id != state.audioApps.last?.id {
                        Divider()
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Permission Warning

    private var permissionWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone access required")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("Volume control needs audio capture permission.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .font(.caption2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No audio apps detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Play audio in any app and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)

            Spacer()

            Toggle(isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.launchAtLogin = $0 }
            )) {
                Text("Launch at Login")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
