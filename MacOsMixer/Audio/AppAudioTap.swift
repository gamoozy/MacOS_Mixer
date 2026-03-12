import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "AppAudioTap")

/// Manages the full audio-interception pipeline for a single application.
///
/// Architecture:
///   CATap (.muted) → Aggregate Device → captureEngine.inputNode
///         installTap captures buffers ↓
///   AVAudioPlayerNode → mixerNode (volume) → playbackEngine.mainMixerNode → speakers
///
/// Two engines decouple tap capture from speaker playback, avoiding format /
/// routing issues with a single-engine aggregate-device approach.
final class AppAudioTap {

    let processObjectID: AudioObjectID
    let bundleID: String

    var volume: Float = 1.0 {
        didSet { mixerNode?.outputVolume = volume }
    }

    var outputDeviceUID: String? {
        didSet {
            guard oldValue != outputDeviceUID else { return }
            reconfigureOutput()
        }
    }

    private(set) var isRunning = false
    private(set) var lastError: String?

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = 0

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?

    init(processObjectID: AudioObjectID, bundleID: String) {
        self.processObjectID = processObjectID
        self.bundleID = bundleID
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        NSLog("[AppAudioTap] Starting tap for %@ (processObj=%d)", bundleID, processObjectID)

        do {
            try createTap()
        } catch {
            lastError = "Tap creation failed: \(error.localizedDescription)"
            throw error
        }

        do {
            try createAggregateDevice()
        } catch {
            lastError = "Aggregate device failed: \(error.localizedDescription)"
            destroyTap()
            throw error
        }

        do {
            try startEngines()
        } catch {
            lastError = "Engine start failed: \(error.localizedDescription)"
            stopEngines()
            destroyAggregateDevice()
            destroyTap()
            throw error
        }

        lastError = nil
        isRunning = true
    }

    func stop() {
        guard isRunning || tapID != AudioObjectID(kAudioObjectUnknown) else { return }

        stopEngines()
        destroyAggregateDevice()
        destroyTap()
        isRunning = false
    }

    // MARK: - CATap

    private func createTap() throws {
        let desc = CATapDescription()
        desc.processes = [processObjectID]
        desc.name = "MacOsMixer.\(bundleID)"
        desc.isPrivate = true
        desc.isMixdown = true
        desc.isMono = false
        desc.muteBehavior = .muted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            NSLog("[AppAudioTap] CreateProcessTap FAILED: status=%d bundle=%@ obj=%d",
                  status, bundleID, processObjectID)
            throw AudioMixerError.tapCreationFailed
        }
        tapID = newTapID
    }

    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Aggregate Device

    private func createAggregateDevice() throws {
        guard let tapUIDStr = tapUID(for: tapID) else {
            throw AudioMixerError.tapCreationFailed
        }

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUIDStr,
            kAudioSubTapDriftCompensationKey: true
        ]

        let aggregateUID = "com.macmixer.aggregate.\(bundleID).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacOsMixer_\(bundleID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]

        var newDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard status == noErr, newDeviceID != 0 else {
            NSLog("[AppAudioTap] CreateAggregateDevice FAILED: status=%d", status)
            throw AudioMixerError.aggregateCreationFailed
        }
        aggregateDeviceID = newDeviceID
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID != 0 else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = 0
    }

    // MARK: - Engines

    private func startEngines() throws {
        let capEng = AVAudioEngine()
        try setDevice(aggregateDeviceID, on: capEng.inputNode)

        let capFormat = capEng.inputNode.outputFormat(forBus: 0)
        guard capFormat.sampleRate > 0, capFormat.channelCount > 0 else {
            throw AudioMixerError.engineStartFailed(
                NSError(domain: "MacOsMixer", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid capture format from tap"]))
        }

        let playEng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        playEng.attach(player)
        playEng.attach(mixer)

        if let uid = outputDeviceUID, let devID = deviceID(forUID: uid) {
            try setDevice(devID, on: playEng.outputNode)
        }

        playEng.connect(player, to: mixer, format: capFormat)
        playEng.connect(mixer, to: playEng.mainMixerNode, format: nil)
        mixer.outputVolume = volume

        try capEng.start()
        try playEng.start()
        player.play()

        capEng.inputNode.installTap(onBus: 0, bufferSize: 2048, format: capFormat) {
            [weak player] buffer, _ in
            player?.scheduleBuffer(buffer)
        }

        captureEngine = capEng
        playbackEngine = playEng
        playerNode = player
        mixerNode = mixer
    }

    private func stopEngines() {
        captureEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        captureEngine?.stop()
        playbackEngine?.stop()

        captureEngine = nil
        playbackEngine = nil
        playerNode = nil
        mixerNode = nil
    }

    // MARK: - Reconfigure

    private func reconfigureOutput() {
        guard isRunning else { return }

        stopEngines()
        destroyAggregateDevice()
        destroyTap()
        isRunning = false

        do { try start() } catch {
            NSLog("[AppAudioTap] Reconfigure FAILED for %@: %@", bundleID, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func setDevice(_ deviceID: AudioObjectID, on node: AVAudioIONode) throws {
        guard let audioUnit = node.audioUnit else {
            throw AudioMixerError.coreAudioError(kAudioUnitErr_InvalidElement)
        }
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            NSLog("[AppAudioTap] setDevice FAILED: device=%d status=%d", deviceID, status)
            throw AudioMixerError.coreAudioError(status)
        }
    }
}
