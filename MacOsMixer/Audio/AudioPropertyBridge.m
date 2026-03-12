// Compiled with -fno-objc-arc (see project.yml) so we can handle
// the raw CFStringRef from CoreAudio without ARC interference.

#import "AudioPropertyBridge.h"

bool AudioObjectGetStringPropertyUTF8(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    char * _Nonnull outBuffer,
    uint32_t bufferSize
) {
    if (bufferSize == 0) return false;
    outBuffer[0] = '\0';

    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope    = scope,
        .mElement  = kAudioObjectPropertyElementMain
    };

    if (!AudioObjectHasProperty(objectID, &address)) {
        return false;
    }

    CFStringRef cfStr = NULL;
    UInt32 size = sizeof(cfStr);
    OSStatus status = AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, &cfStr);

    if (status != noErr || cfStr == NULL) {
        return false;
    }

    // CoreAudio sometimes writes raw ASCII bytes (e.g. "Apple I\0") into the
    // pointer-sized output slot instead of a valid CFStringRef.  This happens
    // for certain properties (kAudioDevicePropertyDeviceManufacturer) and for
    // stale virtual devices from crashed HAL plugins.
    //
    // Detection: real heap pointers contain at least one byte outside the
    // printable-ASCII + null range.  If every byte is 0x00 or 0x20..0x7e, the
    // value is raw string data and MUST NOT be dereferenced.
    uint8_t *raw = (uint8_t *)&cfStr;
    bool allASCII = true;
    for (int i = 0; i < 8; i++) {
        if (raw[i] != 0x00 && (raw[i] < 0x20 || raw[i] > 0x7e)) {
            allASCII = false;
            break;
        }
    }

    if (allASCII) {
        // Salvage the inline string data directly.
        uint32_t copyLen = size < bufferSize ? size : bufferSize - 1;
        memcpy(outBuffer, raw, copyLen);
        outBuffer[copyLen] = '\0';
        return outBuffer[0] != '\0';
    }

    // Convert to UTF-8 via CFString API.
    Boolean ok = CFStringGetCString(cfStr, outBuffer, (CFIndex)bufferSize, kCFStringEncodingUTF8);

    // CoreAudio's Get-rule: caller owns the returned CF reference.
    CFRelease(cfStr);

    return ok;
}
