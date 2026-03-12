import AppKit
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "ProcessMonitor")

/// Watches the system for processes that are currently producing audio.
@Observable
final class ProcessMonitor {

    private(set) var audioApps: [AudioApp] = []

    private var processListListener: AudioPropertyListenerBlock?
    private var pollTimer: Timer?

    init() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
            self?.startListening()
        }
    }

    deinit {
        stopListening()
    }

    // MARK: - Public

    func app(for objectID: AudioObjectID) -> AudioApp? {
        audioApps.first { $0.id == objectID }
    }

    func app(forBundleID bundleID: String) -> AudioApp? {
        audioApps.first { $0.bundleID == bundleID }
    }

    // MARK: - Refresh

    func refresh() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let processObjectIDs: [AudioObjectID] = getAudioPropertyArray(
            systemObject, kAudioHardwarePropertyProcessObjectList
        )

        var seen = Set<String>()
        var apps: [AudioApp] = []

        for objID in processObjectIDs {
            guard let pid: pid_t = getAudioProperty(objID, kAudioProcessPropertyPID) else {
                continue
            }

            // Skip pid 0 (kernel) and our own process
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }

            var bundleID = getAudioPropertyString(objID, kAudioProcessPropertyBundleID) ?? ""

            // Resolve helper processes (e.g. com.brave.Browser.helper → com.brave.Browser)
            let resolvedBundleID = resolveHelperBundleID(bundleID)
            guard !resolvedBundleID.isEmpty else { continue }

            // Deduplicate by resolved bundle ID
            guard !seen.contains(resolvedBundleID) else { continue }
            seen.insert(resolvedBundleID)

            let (name, icon) = appInfo(pid: pid, bundleID: resolvedBundleID)

            // Carry forward existing user settings if this process was already tracked
            var volume: Float = 1.0
            var outputDeviceUID: String?
            var isControlled = false
            if let existing = audioApps.first(where: { $0.bundleID == resolvedBundleID }) {
                volume = existing.volume
                outputDeviceUID = existing.outputDeviceUID
                isControlled = existing.isControlled
            }

            apps.append(AudioApp(
                id: objID,
                pid: pid,
                bundleID: resolvedBundleID,
                name: name,
                icon: icon,
                volume: volume,
                outputDeviceUID: outputDeviceUID,
                isControlled: isControlled
            ))
        }

        // Sort alphabetically for stable UI ordering
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        audioApps = apps
        logger.info("Audio processes: \(apps.map(\.name).joined(separator: ", "))")
    }

    // MARK: - Listeners

    private func startListening() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        processListListener = { [weak self] _, _ in
            self?.refresh()
        }
        addAudioPropertyListener(
            systemObject,
            kAudioHardwarePropertyProcessObjectList,
            block: processListListener!
        )

        // CoreAudio doesn't always fire the listener promptly, so supplement
        // with a low-frequency poll.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopListening() {
        pollTimer?.invalidate()
        pollTimer = nil
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let listener = processListListener {
            removeAudioPropertyListener(systemObject, kAudioHardwarePropertyProcessObjectList, block: listener)
        }
    }

    // MARK: - App metadata

    private func appInfo(pid: pid_t, bundleID: String) -> (name: String, icon: NSImage?) {
        // 1) Try the specific PID (works for main-process apps)
        if let runningApp = NSRunningApplication(processIdentifier: pid),
           let name = runningApp.localizedName, !name.isEmpty {
            return (name, runningApp.icon)
        }

        // 2) Find ANY running instance of this bundle ID (works for helpers
        //    resolved to their parent — e.g. Brave helper → com.brave.Browser)
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        )
        if let mainApp = runningApps.first,
           let name = mainApp.localizedName, !name.isEmpty {
            return (name, mainApp.icon)
        }

        // 3) Look up the app bundle on disk
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            return (name, icon)
        }

        // 4) Last resort — use a prettified bundle ID
        let shortName = bundleID.components(separatedBy: ".").last ?? bundleID
        return (shortName, nil)
    }
}
