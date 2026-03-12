import CoreAudio
import Foundation

// MARK: - Property address builder

func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - Generic property readers

func audioObjectPropertySize(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var address = audioPropertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    return status == noErr ? size : nil
}

func getAudioProperty<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> T? {
    var address = audioPropertyAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    return status == noErr ? buffer.pointee : nil
}

func getAudioPropertyString(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    // Use a C-string bridge to avoid all ARC/autorelease-pool issues that
    // occur when returning CFString/NSString across the ObjC→Swift boundary
    // during early app initialization.
    var buffer = [CChar](repeating: 0, count: 1024)
    let ok = AudioObjectGetStringPropertyUTF8(objectID, selector, scope, &buffer, UInt32(buffer.count))
    guard ok else { return nil }
    return String(cString: buffer)
}

func getAudioPropertyArray<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [T] {
    guard let totalSize = audioObjectPropertySize(objectID, selector, scope: scope),
          totalSize > 0 else { return [] }
    let count = Int(totalSize) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    var address = audioPropertyAddress(selector, scope: scope)
    var size = totalSize
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

// MARK: - Property listener

typealias AudioPropertyListenerBlock = (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>) -> Void

@discardableResult
func addAudioPropertyListener(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    queue: DispatchQueue = .main,
    block: @escaping AudioPropertyListenerBlock
) -> Bool {
    var address = audioPropertyAddress(selector, scope: scope)
    let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
    return status == noErr
}

@discardableResult
func removeAudioPropertyListener(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    queue: DispatchQueue = .main,
    block: @escaping AudioPropertyListenerBlock
) -> Bool {
    var address = audioPropertyAddress(selector, scope: scope)
    let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    return status == noErr
}

// MARK: - Convenience: system default output device

func systemDefaultOutputDeviceID() -> AudioObjectID? {
    getAudioProperty(
        AudioObjectID(kAudioObjectSystemObject),
        kAudioHardwarePropertyDefaultOutputDevice
    )
}

func systemDefaultOutputDeviceUID() -> String? {
    guard let deviceID = systemDefaultOutputDeviceID() else { return nil }
    return getAudioPropertyString(deviceID, kAudioDevicePropertyDeviceUID)
}

// MARK: - Device ID ↔ UID conversion

func deviceID(forUID uid: String) -> AudioObjectID? {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    let allDeviceIDs: [AudioObjectID] = getAudioPropertyArray(
        systemObject, kAudioHardwarePropertyDevices
    )
    for devID in allDeviceIDs {
        if let devUID = getAudioPropertyString(devID, kAudioDevicePropertyDeviceUID),
           devUID == uid {
            return devID
        }
    }
    return nil
}

// MARK: - Tap UID helper

func tapUID(for tapID: AudioObjectID) -> String? {
    getAudioPropertyString(tapID, kAudioTapPropertyUID)
}
