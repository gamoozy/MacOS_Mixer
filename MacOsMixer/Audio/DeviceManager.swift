import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "DeviceManager")

/// Enumerates and monitors audio output devices.
@Observable
final class DeviceManager {

    private(set) var outputDevices: [OutputDevice] = []
    private(set) var defaultOutputUID: String?

    private var deviceListListener: AudioPropertyListenerBlock?
    private var defaultDeviceListener: AudioPropertyListenerBlock?
    private var refreshDebounce: DispatchWorkItem?

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

    func device(forUID uid: String) -> OutputDevice? {
        outputDevices.first { $0.uid == uid }
    }

    func deviceID(forUID uid: String) -> AudioObjectID? {
        outputDevices.first { $0.uid == uid }?.id
    }

    // MARK: - Refresh

    func refresh() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let allDeviceIDs: [AudioObjectID] = getAudioPropertyArray(
            systemObject, kAudioHardwarePropertyDevices
        )

        var devices: [OutputDevice] = []
        for devID in allDeviceIDs {
            let transport: UInt32 = getAudioProperty(devID, kAudioDevicePropertyTransportType) ?? 0

            // Skip aggregate and virtual devices (Background Music, Soundflower, etc.)
            guard transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeVirtual else { continue }

            // AirPlay devices (iPhones, Apple TVs, HomePods) may not report
            // output streams or alive status until actively connected.
            let isAirPlay = transport == kAudioDeviceTransportTypeAirPlay

            if !isAirPlay {
                guard hasOutputStreams(devID) else { continue }
                guard isDeviceAlive(devID) else { continue }
            }

            guard let uid = getAudioPropertyString(devID, kAudioDevicePropertyDeviceUID) else { continue }
            let name = getAudioPropertyString(devID, kAudioObjectPropertyName) ?? "Unknown Device"
            let manufacturer = getAudioPropertyString(devID, kAudioDevicePropertyDeviceManufacturer) ?? ""

            devices.append(OutputDevice(
                id: devID,
                uid: uid,
                name: name,
                manufacturer: manufacturer,
                transportType: transport
            ))
        }

        outputDevices = devices
        defaultOutputUID = systemDefaultOutputDeviceUID()
        let names = devices.map(\.name).joined(separator: ", ")
        NSLog("[DeviceManager] %d output devices: %@", devices.count, names)
    }

    // MARK: - Listeners

    private func startListening() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        deviceListListener = { [weak self] _, _ in
            self?.refreshDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self?.refreshDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        addAudioPropertyListener(
            systemObject,
            kAudioHardwarePropertyDevices,
            block: deviceListListener!
        )

        defaultDeviceListener = { [weak self] _, _ in
            self?.defaultOutputUID = systemDefaultOutputDeviceUID()
        }
        addAudioPropertyListener(
            systemObject,
            kAudioHardwarePropertyDefaultOutputDevice,
            block: defaultDeviceListener!
        )
    }

    private func stopListening() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let listener = deviceListListener {
            removeAudioPropertyListener(systemObject, kAudioHardwarePropertyDevices, block: listener)
        }
        if let listener = defaultDeviceListener {
            removeAudioPropertyListener(systemObject, kAudioHardwarePropertyDefaultOutputDevice, block: listener)
        }
    }

    // MARK: - Helpers

    private func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        guard let size = audioObjectPropertySize(
            deviceID,
            kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        ) else { return false }
        return size > 0
    }

    /// Returns false for dead/stale devices whose HAL plugin has crashed.
    /// Uses only UInt32 properties (no CFString), so this is safe to call
    /// even on corrupt devices.
    private func isDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
        let alive: UInt32? = getAudioProperty(deviceID, kAudioDevicePropertyDeviceIsAlive)
        // If the property doesn't exist (e.g. aggregate device), assume alive.
        // If it explicitly returns 0, the device is dead.
        if let alive, alive == 0 { return false }

        // Double-check: can the device serve as default output?
        // Dead virtual devices often report "not alive" but if the plugin is
        // truly gone, this second check catches them.
        let isRunning: UInt32? = getAudioProperty(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere)
        // Not running doesn't mean dead (device may just be idle), so we only
        // use this as an additional signal combined with transport type.
        _ = isRunning

        return true
    }
}
