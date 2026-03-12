import AppKit
import CoreAudio

// MARK: - Output Device

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let manufacturer: String
    let transportType: UInt32

    var isBuiltInSpeaker: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    var iconName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:     return "speaker.wave.2.fill"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:  return "headphones"
        case kAudioDeviceTransportTypeUSB:          return "cable.connector"
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:  return "tv"
        case kAudioDeviceTransportTypeAirPlay:      return "airplayaudio"
        default:                                    return "speaker.wave.2"
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Audio App (process currently producing audio)

struct AudioApp: Identifiable {
    let id: AudioObjectID          // CoreAudio process object ID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?

    var volume: Float = 1.0
    var outputDeviceUID: String?   // nil = system default
    var isControlled: Bool = false  // true when tap is active
}

extension AudioApp: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.volume == rhs.volume
            && lhs.outputDeviceUID == rhs.outputDeviceUID
            && lhs.isControlled == rhs.isControlled
    }
}

extension AudioApp: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Persisted per-app prefs

struct AppPreference: Codable {
    var volume: Float
    var outputDeviceUID: String?
}

// MARK: - Audio Errors

enum AudioMixerError: LocalizedError {
    case coreAudioError(OSStatus)
    case tapCreationFailed
    case aggregateCreationFailed
    case engineStartFailed(Error)
    case processNotFound

    var errorDescription: String? {
        switch self {
        case .coreAudioError(let status):
            return "Core Audio error: \(status)"
        case .tapCreationFailed:
            return "Failed to create audio tap"
        case .aggregateCreationFailed:
            return "Failed to create aggregate audio device"
        case .engineStartFailed(let err):
            return "Audio engine failed to start: \(err.localizedDescription)"
        case .processNotFound:
            return "Audio process not found"
        }
    }
}

// MARK: - Well-known helper → parent bundle-ID mapping

/// Some apps spawn helper processes for audio playback.  The helper's bundle ID
/// differs from the parent app's.  This table maps helpers back to their parent
/// so the UI can show the correct application name and icon.
let helperBundleIDMap: [String: String] = [
    // Safari
    "com.apple.WebKit.WebContent":                  "com.apple.Safari",
    "com.apple.WebKit.GPU":                         "com.apple.Safari",
    // Chrome
    "com.google.Chrome.helper":                     "com.google.Chrome",
    "com.google.Chrome.helper.renderer":            "com.google.Chrome",
    "com.google.Chrome.helper.gpu":                 "com.google.Chrome",
    // Brave
    "com.brave.Browser.helper":                     "com.brave.Browser",
    "com.brave.Browser.helper.renderer":            "com.brave.Browser",
    "com.brave.Browser.helper.gpu":                 "com.brave.Browser",
    // Edge
    "com.microsoft.edgemac.helper":                 "com.microsoft.edgemac",
    "com.microsoft.edgemac.helper.renderer":        "com.microsoft.edgemac",
    // Firefox
    "org.mozilla.plugincontainer":                  "org.mozilla.firefox",
    "org.mozilla.firefox.helper":                   "org.mozilla.firefox",
    // Arc
    "company.thebrowser.Browser.helper":            "company.thebrowser.Browser",
    "company.thebrowser.Browser.helper.renderer":   "company.thebrowser.Browser",
    // Electron (Slack, Discord, VS Code, etc.)
    "com.electron.app.helper":                      "com.electron.app",
    // Zoom
    "us.zoom.CptHost":                              "us.zoom.xos",
    // Spotify (sometimes uses helper)
    "com.spotify.client.helper":                    "com.spotify.client",
]

/// Attempt to resolve unknown helper bundle IDs by stripping common suffixes.
/// Returns the parent app's bundle ID if found in the running apps or via
/// NSWorkspace, or the original bundleID unchanged.
func resolveHelperBundleID(_ bundleID: String) -> String {
    if let mapped = helperBundleIDMap[bundleID] { return mapped }

    // Strip ".helper", ".helper.renderer", ".helper.gpu", etc.
    let suffixes = [".helper.renderer", ".helper.gpu", ".helper", ".CptHost"]
    for suffix in suffixes {
        if bundleID.hasSuffix(suffix) {
            let parent = String(bundleID.dropLast(suffix.count))
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parent) != nil {
                return parent
            }
        }
    }

    return bundleID
}
