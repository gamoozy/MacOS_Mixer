#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

/// Reads a CFString property from a CoreAudio object and writes it as a
/// UTF-8 C string into the provided buffer.  Returns true on success.
///
/// This avoids all ObjC/Swift ARC bridging issues by never returning a
/// reference-counted object across the language boundary.
bool AudioObjectGetStringPropertyUTF8(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    char * _Nonnull outBuffer,
    uint32_t bufferSize
);
