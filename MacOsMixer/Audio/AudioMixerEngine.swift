import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "AudioMixerEngine")

/// Orchestrates `AppAudioTap` instances for all detected audio applications.
///
/// Taps are eagerly pre-warmed at volume 1.0 during periodic sync so that
/// slider adjustments are instant (no pipeline setup delay). Taps are torn
/// down only when an app exits or the user explicitly resets it.
@Observable
final class AudioMixerEngine {

    /// Active taps keyed by app bundle ID (includes running AND failed taps).
    private var activeTaps: [String: AppAudioTap] = [:]

    /// Timestamps of recent tap creation failures to avoid retrying every frame.
    private var failedAt: [String: Date] = [:]

    private static let retryInterval: TimeInterval = 5.0

    // MARK: - Warm-up

    /// Pre-creates a tap at full volume so slider adjustments are instant.
    /// Called during periodic sync for every detected audio app.
    /// Restores volume and output device if the tap had to be recreated.
    func warmUp(processObjectID: AudioObjectID, bundleID: String,
                volume: Float = 1.0, outputDeviceUID: String? = nil) {
        if activeTaps[bundleID]?.isRunning == true { return }
        if let failTime = failedAt[bundleID],
           Date().timeIntervalSince(failTime) < Self.retryInterval { return }
        let _ = createTap(processObjectID: processObjectID, bundleID: bundleID)
        if let tap = activeTaps[bundleID], tap.isRunning {
            tap.volume = volume
            if tap.outputDeviceUID != outputDeviceUID {
                tap.outputDeviceUID = outputDeviceUID
            }
        }
    }

    // MARK: - Control

    /// Adjusts volume for the given process. The tap should already be warm;
    /// if not, it will be created on demand.
    @discardableResult
    func setVolume(
        _ volume: Float,
        forProcessObjectID objectID: AudioObjectID,
        bundleID: String,
        outputDeviceUID: String?
    ) -> String? {
        if let existing = activeTaps[bundleID] {
            if existing.isRunning {
                existing.volume = volume
                if existing.outputDeviceUID != outputDeviceUID {
                    existing.outputDeviceUID = outputDeviceUID
                }
                return nil
            }
            if let failTime = failedAt[bundleID],
               Date().timeIntervalSince(failTime) < Self.retryInterval {
                return existing.lastError ?? "Tap creation failed, retrying in a few seconds…"
            }
        }

        let error = createTap(processObjectID: objectID, bundleID: bundleID)
        if let tap = activeTaps[bundleID], tap.isRunning {
            tap.volume = volume
            if tap.outputDeviceUID != outputDeviceUID {
                tap.outputDeviceUID = outputDeviceUID
            }
        }
        return error
    }

    /// Changes the output device for a controlled app.
    func setOutputDevice(
        uid: String?,
        forProcessObjectID objectID: AudioObjectID,
        bundleID: String,
        currentVolume: Float
    ) {
        if let existing = activeTaps[bundleID], existing.isRunning {
            existing.outputDeviceUID = uid
            return
        }

        let _ = createTap(processObjectID: objectID, bundleID: bundleID)
        if let tap = activeTaps[bundleID], tap.isRunning {
            tap.outputDeviceUID = uid
        }
    }

    /// Tears down all taps (e.g., on app quit).
    func stopAll() {
        for (_, tap) in activeTaps { tap.stop() }
        activeTaps.removeAll()
        failedAt.removeAll()
    }

    /// Removes taps for processes that are no longer in the process list.
    func pruneStale(activeProcessBundleIDs: Set<String>) {
        let stale = activeTaps.keys.filter { !activeProcessBundleIDs.contains($0) }
        for bundleID in stale {
            NSLog("[AudioMixerEngine] Pruning stale tap for %@", bundleID)
            activeTaps[bundleID]?.stop()
            activeTaps.removeValue(forKey: bundleID)
            failedAt.removeValue(forKey: bundleID)
        }
    }

    /// Whether a given app currently has an active, running tap.
    func isControlled(bundleID: String) -> Bool {
        activeTaps[bundleID]?.isRunning == true
    }

    /// Explicitly tears down a tap (e.g., user resets an app to defaults).
    func resetTap(for bundleID: String) {
        releaseTap(for: bundleID)
    }

    /// Force-retry tap creation for a bundle (e.g., after granting permissions).
    func retryTap(processObjectID: AudioObjectID, bundleID: String) {
        releaseTap(for: bundleID)
        failedAt.removeValue(forKey: bundleID)
        let _ = createTap(processObjectID: processObjectID, bundleID: bundleID)
    }

    // MARK: - Internal

    private func createTap(processObjectID: AudioObjectID, bundleID: String) -> String? {
        activeTaps[bundleID]?.stop()

        let tap = AppAudioTap(processObjectID: processObjectID, bundleID: bundleID)
        activeTaps[bundleID] = tap

        do {
            try tap.start()
            failedAt.removeValue(forKey: bundleID)
            NSLog("[AudioMixerEngine] Tap started for %@ (processObj=%d)", bundleID, processObjectID)
            return nil
        } catch {
            let msg = error.localizedDescription
            failedAt[bundleID] = Date()
            NSLog("[AudioMixerEngine] FAILED to start tap for %@: %@", bundleID, msg)
            return msg
        }
    }

    private func releaseTap(for bundleID: String) {
        guard let tap = activeTaps.removeValue(forKey: bundleID) else { return }
        tap.stop()
        failedAt.removeValue(forKey: bundleID)
        NSLog("[AudioMixerEngine] Released tap for %@", bundleID)
    }
}
