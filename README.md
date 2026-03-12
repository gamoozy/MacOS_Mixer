# MacOs Mixer

A lightweight macOS menu bar application for per-application audio volume control and multi-output routing. Built entirely with Swift, CoreAudio, and SwiftUI — no kernel extensions, no virtual audio drivers, no third-party dependencies.

![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange) ![License MIT](https://img.shields.io/badge/license-MIT-green)

---

## Features

- **Per-app volume control** — independent slider for every audio-producing process
- **Per-app output routing** — send each app to a different speaker/headphone simultaneously (e.g. Brave → headphones, WhatsApp → MacBook speakers)
- **Simultaneous multi-output** — any number of apps can be routed to different physical outputs at the same time
- **Real-time process detection** — apps appear as soon as they produce audio and disappear when they stop
- **App icons** — resolves helper processes (browser renderers, Zoom, Spotify helpers) back to their parent app's name and icon
- **Persistent preferences** — volume and device routing are saved per-app and restored on next launch
- **Menu bar only** — no Dock icon, instant popover from the menu bar
- **Smooth transitions** — volume changes are instantaneous; all taps are pre-warmed at launch
- **Real hardware devices only** — virtual/aggregate devices (Background Music, Soundflower) are filtered out of the picker

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | **14.2 Sonoma** or later (requires `CATapDescription` / `AudioHardwareCreateProcessTap`) |
| Xcode | 15.2 or later |
| Swift | 5.9 |

> **Why macOS 14.2?** The `AudioHardwareCreateProcessTap` API — which allows per-process audio interception without a kernel extension — was introduced in macOS 14.2. Earlier macOS versions require a virtual audio driver (e.g. BlackHole, Loopback), which this project intentionally avoids.

---

## Project Structure

```
MacOs_Mixer/
├── MacOsMixer.xcodeproj/          # Xcode project
├── project.yml                    # XcodeGen configuration
└── MacOsMixer/
    ├── App/
    │   └── MacOsMixerApp.swift    # AppDelegate, NSStatusItem, NSPopover
    ├── Audio/
    │   ├── AppAudioTap.swift      # Per-app audio pipeline (CATap → AVAudioEngine)
    │   ├── AudioMixerEngine.swift # Orchestrates all AppAudioTap instances
    │   ├── ProcessMonitor.swift   # Detects audio-producing processes via CoreAudio
    │   ├── DeviceManager.swift    # Enumerates physical output devices
    │   ├── CoreAudioHelper.swift  # Swift wrappers for CoreAudio C APIs
    │   ├── AudioPropertyBridge.h  # Obj-C bridge header
    │   └── AudioPropertyBridge.m  # Safe CFStringRef reading via C function
    ├── Models/
    │   └── AudioTypes.swift       # OutputDevice, AudioApp, AppPreference, errors
    ├── ViewModels/
    │   └── MixerState.swift       # @Observable bridge between audio engine and UI
    ├── Views/
    │   ├── MixerPopoverView.swift  # Main popover container
    │   └── AppAudioRowView.swift   # Per-app row: icon, slider, device picker
    ├── Persistence/
    │   └── PersistenceManager.swift # UserDefaults-backed preference storage
    ├── MacOsMixer.entitlements    # com.apple.security.device.audio-input
    └── Info.plist
```

---

## How It Works — Architecture Deep Dive

### 1. Process Detection (`ProcessMonitor`)

CoreAudio exposes every process currently registered with the HAL (Hardware Abstraction Layer) via `kAudioHardwarePropertyProcessObjectList`. For each process object, we read:
- `kAudioProcessPropertyPID` — the Unix PID
- `kAudioProcessPropertyBundleID` — the bundle identifier

Many apps (browsers, Zoom, Spotify) use helper processes for audio. We resolve these back to their parent app using a lookup table (`helperBundleIDMap`) and a generic suffix-stripping heuristic (`.helper`, `.helper.renderer`, etc.).

App name and icon are fetched via `NSRunningApplication` (by PID, then by bundle ID) and `NSWorkspace`.

### 2. Audio Interception — CATap API (`AppAudioTap`)

Each audio-producing app gets its own `AppAudioTap` instance. The pipeline for a single app is:

```
App's audio output (kernel)
        ↓
CATapDescription (muteBehavior = .muted)
        ↓  AudioHardwareCreateProcessTap()
CATap (AudioObjectID)
        ↓
HAL Aggregate Device (AudioHardwareCreateAggregateDevice)
        ↓
captureEngine.inputNode  ← AVAudioEngine #1
        ↓  installTap(onBus:0)
PCM buffer (AVAudioPCMBuffer)
        ↓  scheduleBuffer()
AVAudioPlayerNode
        ↓
AVAudioMixerNode  ← outputVolume = user's slider value
        ↓
playbackEngine.mainMixerNode  ← AVAudioEngine #2
        ↓  setDevice(targetDeviceID, on: outputNode)
Physical audio output device (speakers / headphones)
```

**Two-engine design**: The capture and playback engines are intentionally separate objects. A single `AVAudioEngine` cannot simultaneously act as an input to an aggregate-tap device and output to an arbitrary physical device without format and routing conflicts. Decoupling them via a buffer bridge (`scheduleBuffer`) eliminates all those issues.

**Mute behavior**: `CATapDescription.muteBehavior = .muted` silences the app's original output through the system's normal path, so audio only comes out through our controlled pipeline. This is what enables volume control and routing.

**Pre-warming**: All taps are created eagerly at launch (and whenever new processes appear) at volume 1.0. This means when the user first moves a slider, the pipeline is already running — the change is just a `mixer.outputVolume` assignment, with no setup delay or audio gap.

### 3. Device Enumeration (`DeviceManager`)

We enumerate `kAudioHardwarePropertyDevices` and filter:
- **Keep**: built-in, USB, Bluetooth, HDMI/DisplayPort, AirPlay devices
- **Skip**: `kAudioDeviceTransportTypeAggregate` — our own tap aggregate devices
- **Skip**: `kAudioDeviceTransportTypeVirtual` — third-party virtual devices (Background Music, Soundflower, etc.)

A debounced listener on `kAudioHardwarePropertyDevices` refreshes the list whenever hardware changes (plug/unplug headphones, connect Bluetooth, etc.).

> **iPhone / AirPlay**: iPhones and AirPlay targets do not appear in Core Audio's device list until you first connect to them through macOS Control Center → Sound → AirPlay. Once connected, they register as a Core Audio device and automatically appear in the mixer's output dropdown.

### 4. Volume & Routing Control (`AudioMixerEngine` + `MixerState`)

- **Volume**: stored as `mixer.outputVolume` on the `AVAudioMixerNode` inside the playback engine. Changes are instant.
- **Output device change**: calls `reconfigureOutput()` on the tap, which does a full pipeline teardown and rebuild with the new device. Takes ~100ms; the original audio is briefly silent during the transition.
- **Multi-output**: each `AppAudioTap` has its own independent playback engine, pointed at its own output device. Changing one app's routing never touches another app's pipeline.

`MixerState` bridges the audio engine to SwiftUI. It runs a 2-second sync timer to detect new/removed processes, merge state, and warm up taps. Preferences are written to `UserDefaults` with a 0.5s debounce to coalesce rapid slider moves into a single disk write.

### 5. UI (`MixerPopoverView` + `AppAudioRowView`)

- `NSStatusBar` + `NSPopover` — more reliable than SwiftUI's `MenuBarExtra` for menu bar presence
- `@Observable` for reactive updates — no `@Published` boilerplate
- `AudioApp.Equatable` compares `id + volume + outputDeviceUID + isControlled` so SwiftUI re-renders the picker when the device changes
- `localVolume` state in each row prevents the slider from jumping during drag when background syncs update `app.volume`

### 6. Safe CoreAudio String Reading (`AudioPropertyBridge`)

CoreAudio returns string properties as `CFStringRef`. Reading these naively in Swift causes `EXC_BAD_ACCESS` crashes during early app init (before the Objective-C autorelease pool is set up). The fix: a pure-C function `AudioObjectGetStringPropertyUTF8` (in `AudioPropertyBridge.m`) reads the property into a `char[]` buffer, bypassing Swift ARC entirely.

---

## Build Instructions

### Option A — Xcode GUI

1. Clone the repo:
   ```bash
   git clone https://github.com/gamoozy/MacOS_Mixer.git
   cd MacOS_Mixer
   ```
2. Open `MacOsMixer.xcodeproj` in Xcode 15.2+
3. Select the **MacOsMixer** scheme and your Mac as the target
4. Press **⌘R** to build and run

### Option B — Command Line

```bash
git clone https://github.com/gamoozy/MacOS_Mixer.git
cd MacOS_Mixer

xcodebuild \
  -project MacOsMixer.xcodeproj \
  -scheme MacOsMixer \
  -configuration Release \
  -derivedDataPath build \
  ONLY_ACTIVE_ARCH=NO

# Copy to Applications
cp -R "build/Build/Products/Release/MacOs Mixer.app" /Applications/MacOsMixer.app

# Launch (run from /tmp to avoid Gatekeeper sandbox conflicts with NSStatusItem)
cp "/Applications/MacOsMixer.app/Contents/MacOS/MacOs Mixer" /tmp/MacOsMixer_bin
chmod +x /tmp/MacOsMixer_bin
/tmp/MacOsMixer_bin &
```

### Permissions

On first launch, macOS will prompt for **Microphone** access. This permission is required for `AudioHardwareCreateProcessTap` to intercept audio. If you deny it accidentally:

> **System Settings → Privacy & Security → Microphone → MacOs Mixer → Enable**

---

## Usage

1. Launch the app — a mixer icon (⊞) appears in the menu bar
2. Click the icon to open the mixer popover
3. Every app currently producing audio appears as a row with:
   - **App icon + name**
   - **Volume slider** (0–100%) — instant, no audio gap
   - **Output device dropdown** — System Default, or any physical output device
4. To route two apps to different outputs simultaneously:
   - Set App A's dropdown to **External Headphones**
   - Set App B's dropdown to **MacBook Pro Speakers**
   - Both play through their respective outputs independently
5. Settings are **automatically saved** — restored on next launch
6. To reset an app to defaults, click the **↩** button that appears when it's controlled

---

## Technical Challenges & Solutions

| Challenge | Solution |
|---|---|
| Per-app audio interception without a kernel extension | `AudioHardwareCreateProcessTap` (macOS 14.2+) |
| `EXC_BAD_ACCESS` reading `CFStringRef` from CoreAudio | Pure-C `AudioObjectGetStringPropertyUTF8` bridge in Obj-C |
| Audio gap when first moving slider from 100% | Pre-warm all taps at launch so volume change = property assignment only |
| Menu bar icon not appearing reliably | `NSStatusBar` + `NSPopover` (more reliable than SwiftUI `MenuBarExtra`) |
| Format mismatch between tap (mono) and speakers (stereo) | Two-engine architecture; `AVAudioMixerNode` handles upmix automatically |
| Stale device picker UI after routing change | `AudioApp.Equatable` includes `outputDeviceUID` so SwiftUI diffs correctly |
| Slider jumps during background sync while dragging | `isDragging` state gate prevents `app.volume` syncs from overriding `localVolume` |
| Volume slider resets device selection back to previous | Read `audioApps[idx].outputDeviceUID` (live state) not `app.outputDeviceUID` (stale capture) |
| `DeviceManager` refresh firing 20+ times per tap creation | Debounced `DispatchWorkItem` on `kAudioHardwarePropertyDevices` listener |

---

## Known Limitations

- **macOS 14.2+ only** — the `AudioHardwareCreateProcessTap` API does not exist on earlier versions
- **Microphone permission required** — macOS treats process audio taps as audio input access
- **~100ms gap when switching output device** — the tap pipeline is fully rebuilt on device change; audio resumes automatically
- **iPhone / AirPlay** — must first be connected via Control Center → Sound before appearing in the device list
- **Apps that use private audio sessions** — some DRM-protected apps (e.g. Apple Music with DRM tracks) may reject tapping

---

## File-by-File Reference

| File | Responsibility |
|---|---|
| `MacOsMixerApp.swift` | App entry point, `NSStatusItem` setup, microphone permission request |
| `AppAudioTap.swift` | Full per-app audio pipeline: CATap → aggregate device → two AVAudioEngines |
| `AudioMixerEngine.swift` | Manages a dictionary of `AppAudioTap` instances; handles warm-up, volume, routing, pruning |
| `ProcessMonitor.swift` | Polls `kAudioHardwarePropertyProcessObjectList`; resolves helper bundle IDs; fetches app icons |
| `DeviceManager.swift` | Enumerates physical output devices; listens for device plug/unplug events |
| `CoreAudioHelper.swift` | Generic Swift wrappers: property readers, array readers, listener add/remove |
| `AudioPropertyBridge.m` | C-level `CFStringRef` reader to avoid Swift ARC crashes in CoreAudio |
| `MixerState.swift` | `@Observable` view-model; syncs engine state to UI; debounced persistence |
| `MixerPopoverView.swift` | Main SwiftUI popover: header, app list, empty state, footer |
| `AppAudioRowView.swift` | Per-app row: icon, name, volume slider, device picker, reset button |
| `AudioTypes.swift` | Data models: `OutputDevice`, `AudioApp`, `AppPreference`, `AudioMixerError` |
| `PersistenceManager.swift` | `UserDefaults`-backed JSON store for per-app volume + device preferences |

---

## License

MIT — see [LICENSE](LICENSE) for details.
