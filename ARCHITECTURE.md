# MacOs Mixer — System Architecture

## 1. Overview

MacOs Mixer is a lightweight macOS menu-bar application that provides **per-application
audio volume control** and **per-application output device routing**.  It lets you,
for example, send Zoom audio to headphones at 80 % volume while YouTube plays
through speakers at 50 %.

**Minimum macOS version:** 14.2 (Sonoma) — required by the Core Audio Tap API.

---

## 2. How macOS Audio Works (Background)

### 2.1 Core Audio HAL

macOS audio is managed by **Core Audio** through the **Hardware Abstraction Layer
(HAL)**.  Every application that plays sound sends PCM buffers to `coreaudiod`,
which mixes them and forwards the result to the active output device.

Historically, there is **no public per-application volume knob** — the system
provides only a single master volume.  Tools like *Background Music* worked around
this by installing a custom HAL driver (kernel extension or user-space plug-in) that
intercepts audio before it reaches the real hardware.  That approach requires
privileged installation, breaks with macOS updates, and cannot ship on the App Store.

### 2.2 The Core Audio Tap API (macOS 14.2+)

Starting with macOS 14.2, Apple introduced a first-party mechanism:

| Symbol | Purpose |
|---|---|
| `CATapDescription` | Describes which process(es) to tap and how |
| `AudioHardwareCreateProcessTap` | Creates a tap, returns an `AudioObjectID` |
| `AudioHardwareDestroyProcessTap` | Tears down a tap |
| `kAudioHardwarePropertyProcessObjectList` | Enumerates all audio-producing processes |

A **tap** captures the outgoing audio of one or more processes.  Key properties:

* **`processes`** — array of `AudioObjectID` values identifying target processes.
* **`muteBehavior`** — `.unmuted` (passthrough), `.muted` (silence the original),
  or `.mutedWhenTapped` (mute only while a client reads from the tap).
* **`isMixdown`** / **`isMono`** — force a stereo or mono mixdown.
* **`isPrivate`** — hide the tap from other processes.

A tap materialises as an **input stream** inside a **HAL aggregate device**, so
standard Core Audio I/O mechanisms can read from it.

### 2.3 Aggregate Devices

An aggregate device is a lightweight, user-space construct that combines multiple
audio sub-devices and/or taps into a single virtual device.  It is created with
`AudioHardwareCreateAggregateDevice` and destroyed with
`AudioHardwareDestroyAggregateDevice`.  No drivers or extensions are installed.

---

## 3. Audio Routing Strategy

### 3.1 Per-Application Audio Pipeline

For every application the user wants to control, MacOs Mixer establishes the
following real-time pipeline:

```
┌─────────┐   muteBehavior = .muted    ┌─────────────┐
│  App     │ ─────────────────────────► │  CATap      │
│ (Zoom)   │   original output muted    │ (captures   │
└─────────┘                             │  PCM data)  │
                                        └──────┬──────┘
                                               │ tap UID
                                               ▼
                                     ┌──────────────────┐
                                     │ Aggregate Device  │
                                     │ (tap = input)     │
                                     └──────────┬───────┘
                                                │
                                                ▼
                                     ┌──────────────────┐
                                     │  AVAudioEngine    │
                                     │  ┌────────────┐  │
                                     │  │ inputNode   │  │
                                     │  └─────┬──────┘  │
                                     │        │         │
                                     │  ┌─────▼──────┐  │
                                     │  │ MixerNode   │──┤── volume (0.0 – 1.0)
                                     │  └─────┬──────┘  │
                                     │        │         │
                                     │  ┌─────▼──────┐  │
                                     │  │ outputNode  │──┤── target device
                                     │  └────────────┘  │
                                     └──────────────────┘
                                                │
                                                ▼
                                     ┌──────────────────┐
                                     │ Physical Output   │
                                     │ (Headphones,      │
                                     │  Speakers, HDMI)  │
                                     └──────────────────┘
```

**Step-by-step:**

1. Create a `CATapDescription` targeting the application's `AudioObjectID` with
   `muteBehavior = .muted` so the original output is silenced.
2. Call `AudioHardwareCreateProcessTap` → obtain a tap `AudioObjectID`.
3. Read the tap's UID via `kAudioTapPropertyUID`.
4. Create an aggregate device whose `kAudioAggregateDeviceTapListKey` includes
   the tap UID.  This aggregate device now has an input stream carrying the
   application's audio.
5. Instantiate an `AVAudioEngine`.  Set its **inputNode** device to the aggregate
   (via `kAudioOutputUnitProperty_CurrentDevice` on the underlying AudioUnit).
6. Attach an `AVAudioMixerNode` for volume control.
7. Set the **outputNode** device to the user's chosen physical output.
8. Connect the graph: `inputNode → mixerNode → outputNode`.
9. Start the engine.

Volume changes are instant — just set `mixerNode.outputVolume`.
Output-device changes require stopping the engine, reconfiguring the outputNode
device, and restarting.

### 3.2 Lazy Activation

To minimise resource usage, taps and engines are **not** created until the user
actually adjusts an application's volume or routing.  Untouched applications
continue to play normally through the system default output.

When the user resets an application back to 100 % volume on the default device,
the pipeline is torn down and the application reverts to native playback.

### 3.3 Multi-Output Routing

Different applications can be routed to different physical devices simultaneously
because each application has its own independent `AVAudioEngine` with its own
output device.  macOS Core Audio supports multiple clients writing to the same
device concurrently — their buffers are mixed by the HAL automatically.

---

## 4. Component Architecture

```
┌──────────────────────────────────────────────────────┐
│                    SwiftUI Layer                      │
│  MacOsMixerApp ── MenuBarExtra (.window style)        │
│       │                                              │
│       └── MixerPopoverView                            │
│              └── AppAudioRowView (per app)             │
│                    • volume slider                    │
│                    • output device picker             │
└────────────────────────┬─────────────────────────────┘
                         │ binds to
                         ▼
┌──────────────────────────────────────────────────────┐
│                   MixerState                          │
│  @Observable view-model aggregating all managers      │
└───┬──────────┬──────────┬──────────┬─────────────────┘
    │          │          │          │
    ▼          ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌──────────┐ ┌──────────────────┐
│Process │ │Device  │ │AudioMixer│ │Persistence       │
│Monitor │ │Manager │ │Engine    │ │Manager           │
└────────┘ └────────┘ └──────────┘ └──────────────────┘
    │          │          │
    │          │          └── owns N × AppAudioTap
    │          │                   │
    ▼          ▼                   ▼
┌──────────────────────────────────────────────────────┐
│              Core Audio (system)                       │
│  kAudioHardwarePropertyProcessObjectList              │
│  kAudioHardwarePropertyDevices                        │
│  AudioHardwareCreateProcessTap / DestroyProcessTap    │
│  AudioHardwareCreateAggregateDevice                   │
│  AVAudioEngine / AVAudioMixerNode                     │
└──────────────────────────────────────────────────────┘
```

### 4.1 ProcessMonitor

* Queries `kAudioHardwarePropertyProcessObjectList` on the system audio object.
* For each `AudioObjectID` process, reads `kAudioProcessPropertyPID` and
  `kAudioProcessPropertyBundleID`.
* Resolves PID → `NSRunningApplication` to obtain app name and icon.
* Installs a property listener to detect when processes start/stop audio.
* Publishes an up-to-date `[AudioApp]` array.

### 4.2 DeviceManager

* Queries `kAudioHardwarePropertyDevices` and filters for output-capable devices.
* Reads device name, UID, manufacturer, transport type.
* Listens for device connect/disconnect events.
* Publishes `[OutputDevice]`.

### 4.3 AppAudioTap

One instance per controlled application.  Owns:

* A `CATapDescription` + tap `AudioObjectID`.
* An aggregate device `AudioObjectID`.
* An `AVAudioEngine` with a `MixerNode`.

Exposes `volume: Float` and `outputDeviceUID: String`.

### 4.4 AudioMixerEngine

Orchestrator that manages the lifecycle of `AppAudioTap` instances.
Responds to process monitor events (new/removed apps) and user actions
(volume change, device change).

### 4.5 PersistenceManager

Stores per-app preferences in `UserDefaults` keyed by bundle identifier:

```json
{
  "com.apple.Safari": { "volume": 0.8, "outputDeviceUID": "BuiltInSpeakerDevice" },
  "us.zoom.xos": { "volume": 0.6, "outputDeviceUID": "AirPodsUID" }
}
```

On launch, restores saved configurations for any matching running processes.

### 4.6 MixerState

`@Observable` view-model that aggregates ProcessMonitor, DeviceManager,
AudioMixerEngine, and PersistenceManager.  Provides the single source of
truth consumed by SwiftUI views.

---

## 5. Technical Challenges and Mitigations

| Challenge | Mitigation |
|---|---|
| **Brief audio glitch** when first intercepting an app (tap creation + engine startup) | Acceptable one-time-per-app glitch.  Could be reduced with pre-warming. |
| **Helper-process bundle IDs** (Safari → `com.apple.WebKit.WebContent`) | Maintain a mapping table of known helpers → parent app bundle IDs. |
| **Format mismatches** between tap and output device (sample rate, channels) | AVAudioEngine handles sample-rate conversion.  Taps forced to stereo mixdown. |
| **Output device hot-plug** (AirPods disconnect mid-stream) | DeviceManager detects removal, engine falls back to system default. |
| **Thread safety** — AVAudioEngine callbacks on audio thread | Volume changes via atomic property on MixerNode (thread-safe).  Device changes stop/restart engine on main queue. |
| **Permission prompt** for audio capture | `NSAudioCaptureUsageDescription` in Info.plist.  First tap triggers system dialog. |
| **CPU with many taps** | Only tap apps the user has configured.  Destroy taps for inactive or default-config apps. |

---

## 6. Project Structure

```
MacOs_Mixer/
├── ARCHITECTURE.md              ← you are here
├── README.md                    ← build & run instructions
├── project.yml                  ← XcodeGen project spec
├── MacOsMixer/
│   ├── Info.plist
│   ├── MacOsMixer.entitlements
│   ├── App/
│   │   └── MacOsMixerApp.swift
│   ├── Models/
│   │   └── AudioTypes.swift
│   ├── Audio/
│   │   ├── CoreAudioHelper.swift
│   │   ├── DeviceManager.swift
│   │   ├── ProcessMonitor.swift
│   │   ├── AppAudioTap.swift
│   │   └── AudioMixerEngine.swift
│   ├── Persistence/
│   │   └── PersistenceManager.swift
│   ├── ViewModels/
│   │   └── MixerState.swift
│   └── Views/
│       ├── MixerPopoverView.swift
│       └── AppAudioRowView.swift
└── .gitignore
```

---

## 7. Why Not a Virtual Audio Driver?

The legacy approach (Background Music, SoundSource pre-v5) installs a HAL
driver plug-in or kernel extension that becomes the system default output.
All application audio flows through it, giving the driver full control.

**Drawbacks:**

* Requires privileged installation (`/Library/Audio/Plug-Ins/HAL`).
* Kernel extensions are deprecated since macOS 11.
* AudioDriverKit (DriverKit) does **not** support virtual devices.
* Cannot ship on the Mac App Store.
* A crash in the driver silences all audio system-wide.

The **Core Audio Tap API** avoids all of these issues.  It runs entirely in
user-space, requires no installation, and each tap is scoped to a specific
process — a tap failure only affects that one application.

---

## 8. Permissions & Entitlements

| Requirement | Location |
|---|---|
| `NSAudioCaptureUsageDescription` | Info.plist — triggers system permission dialog |
| App Sandbox (optional) | Entitlements — can run sandboxed with `com.apple.security.device.audio-input` |
| Hardened Runtime | Entitlements — `com.apple.security.cs.disable-library-validation` may be needed for development |

---

## 9. Future Enhancements

* **10-band per-app EQ** via `AVAudioUnitEQ` inserted between mixer and output.
* **Audio level meters** using `installTap(onBus:)` on the mixer node.
* **Auto-ducking** — lower non-focus apps when a call is active.
* **Keyboard shortcuts** for quick volume adjustments.
* **Aggregate multi-output** — route one app to two devices simultaneously.
