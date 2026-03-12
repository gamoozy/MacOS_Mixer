import Combine
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "MixerState")

/// Central observable state that bridges audio subsystems with the SwiftUI layer.
@Observable
final class MixerState {

    var audioApps: [AudioApp] = []
    var outputDevices: [OutputDevice] = []
    var defaultOutputUID: String?
    var micPermissionGranted: Bool = false
    var lastTapError: String?

    var launchAtLogin: Bool {
        get { LaunchAtLoginManager.isEnabled }
        set { LaunchAtLoginManager.setEnabled(newValue) }
    }

    let processMonitor = ProcessMonitor()
    let deviceManager = DeviceManager()
    let engine = AudioMixerEngine()
    let persistence = PersistenceManager()

    private var syncTimer: Timer?
    private var persistTimer: Timer?
    private var pendingPersist: [String: AppPreference] = [:]

    init() {
        DispatchQueue.main.async { [weak self] in
            self?.sync()
            self?.restoreSavedPreferences()
            self?.startPeriodicSync()
            self?.registerLaunchAtLoginIfNeeded()
        }
    }

    private func registerLaunchAtLoginIfNeeded() {
        let key = "hasRegisteredLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LaunchAtLoginManager.setEnabled(true)
    }

    deinit {
        syncTimer?.invalidate()
        persistTimer?.invalidate()
        engine.stopAll()
    }

    // MARK: - UI Actions

    func setVolume(_ volume: Float, for app: AudioApp) {
        guard let idx = audioApps.firstIndex(where: { $0.bundleID == app.bundleID }) else { return }
        audioApps[idx].volume = volume

        let currentDeviceUID = audioApps[idx].outputDeviceUID
        let isDefault = abs(volume - 1.0) < 0.01 && currentDeviceUID == nil
        audioApps[idx].isControlled = !isDefault

        let error = engine.setVolume(
            volume,
            forProcessObjectID: app.id,
            bundleID: app.bundleID,
            outputDeviceUID: currentDeviceUID
        )
        if let error { lastTapError = error }

        if isDefault {
            persistence.removePreference(for: app.bundleID)
        } else {
            schedulePersist(bundleID: app.bundleID, volume: volume, outputDeviceUID: currentDeviceUID)
        }
    }

    func setOutputDevice(uid: String?, for app: AudioApp) {
        guard let idx = audioApps.firstIndex(where: { $0.bundleID == app.bundleID }) else { return }
        audioApps[idx].outputDeviceUID = uid

        let isDefault = abs(app.volume - 1.0) < 0.01 && uid == nil
        audioApps[idx].isControlled = !isDefault

        engine.setOutputDevice(
            uid: uid,
            forProcessObjectID: app.id,
            bundleID: app.bundleID,
            currentVolume: audioApps[idx].volume
        )

        schedulePersist(bundleID: app.bundleID, volume: audioApps[idx].volume, outputDeviceUID: uid)
    }

    func resetApp(_ app: AudioApp) {
        guard let idx = audioApps.firstIndex(where: { $0.bundleID == app.bundleID }) else { return }
        audioApps[idx].volume = 1.0
        audioApps[idx].outputDeviceUID = nil
        audioApps[idx].isControlled = false

        engine.resetTap(for: app.bundleID)
        persistence.removePreference(for: app.bundleID)
    }

    // MARK: - Sync

    func sync() {
        outputDevices = deviceManager.outputDevices
        defaultOutputUID = deviceManager.defaultOutputUID

        let monitorApps = processMonitor.audioApps
        var merged: [AudioApp] = []

        for var monApp in monitorApps {
            if let existing = audioApps.first(where: { $0.bundleID == monApp.bundleID }) {
                monApp.volume = existing.volume
                monApp.outputDeviceUID = existing.outputDeviceUID
                monApp.isControlled = existing.isControlled
            }
            merged.append(monApp)
        }

        audioApps = merged

        let activeBundleIDs = Set(merged.map(\.bundleID))
        engine.pruneStale(activeProcessBundleIDs: activeBundleIDs)

        for app in merged {
            engine.warmUp(processObjectID: app.id, bundleID: app.bundleID,
                          volume: app.volume, outputDeviceUID: app.outputDeviceUID)
        }
    }

    // MARK: - Persistence

    /// Coalesce rapid volume changes into a single disk write after 0.5s of inactivity.
    private func schedulePersist(bundleID: String, volume: Float, outputDeviceUID: String?) {
        let isDefault = abs(volume - 1.0) < 0.01 && outputDeviceUID == nil
        if isDefault {
            pendingPersist.removeValue(forKey: bundleID)
            persistence.removePreference(for: bundleID)
            return
        }

        pendingPersist[bundleID] = AppPreference(volume: volume, outputDeviceUID: outputDeviceUID)

        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.flushPendingPersist()
        }
    }

    private func flushPendingPersist() {
        for (bundleID, pref) in pendingPersist {
            persistence.save(preference: pref, for: bundleID)
        }
        pendingPersist.removeAll()
    }

    private func restoreSavedPreferences() {
        let prefs = persistence.allPreferences()
        guard !prefs.isEmpty else { return }

        for (bundleID, pref) in prefs {
            guard let idx = audioApps.firstIndex(where: { $0.bundleID == bundleID }) else { continue }
            audioApps[idx].volume = pref.volume
            audioApps[idx].outputDeviceUID = pref.outputDeviceUID

            let isDefault = abs(pref.volume - 1.0) < 0.01 && pref.outputDeviceUID == nil
            audioApps[idx].isControlled = !isDefault

            if !isDefault {
                engine.setVolume(
                    pref.volume,
                    forProcessObjectID: audioApps[idx].id,
                    bundleID: bundleID,
                    outputDeviceUID: pref.outputDeviceUID
                )
            }
        }

        NSLog("[MixerState] Restored preferences for %d app(s)", prefs.count)
    }

    private func startPeriodicSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sync()
        }
    }
}
