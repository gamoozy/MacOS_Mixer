import CoreAudio
import Foundation

let systemObj = AudioObjectID(kAudioObjectSystemObject)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var size: UInt32 = 0
AudioObjectGetPropertyDataSize(systemObj, &addr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioObjectID>.stride
let buf = UnsafeMutablePointer<AudioObjectID>.allocate(capacity: count)
defer { buf.deallocate() }
AudioObjectGetPropertyData(systemObj, &addr, 0, nil, &size, buf)
let devices = Array(UnsafeBufferPointer(start: buf, count: count))

print("Found \(devices.count) devices")
print("sizeof CFString: \(MemoryLayout<CFString>.size)")
print("sizeof UnsafeRawPointer: \(MemoryLayout<UnsafeRawPointer>.size)")

for dev in devices {
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var nameSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(dev, &nameAddr, 0, nil, &nameSize)
    print("\nDevice \(dev): dataSize=\(nameSize) sizeStatus=\(sizeStatus)")

    if nameSize > 0 {
        let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(nameSize), alignment: 8)
        rawBuf.initializeMemory(as: UInt8.self, repeating: 0, count: Int(nameSize))
        defer { rawBuf.deallocate() }

        let status = AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, rawBuf)
        print("  getData status=\(status)")

        // Print raw bytes
        let bytes = Array(UnsafeBufferPointer(
            start: rawBuf.assumingMemoryBound(to: UInt8.self),
            count: Int(nameSize)
        ))
        let hexStr = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  raw bytes (\(nameSize)): \(hexStr)")

        // If it's pointer-sized, try treating as CFStringRef
        if nameSize == UInt32(MemoryLayout<UnsafeRawPointer>.size) {
            let ptrValue = rawBuf.load(as: UInt.self)
            print("  pointer value: 0x\(String(ptrValue, radix: 16))")
        }

        // Try treating as CFString directly
        var cfStr: CFString = "" as CFString
        var cfSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr2 = nameAddr
        let status2 = AudioObjectGetPropertyData(dev, &nameAddr2, 0, nil, &cfSize, &cfStr)
        if status2 == noErr {
            print("  CFString approach: \(cfStr)")
        } else {
            print("  CFString approach failed: \(status2)")
        }
    }
}
