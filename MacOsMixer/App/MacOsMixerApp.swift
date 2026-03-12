import AppKit
import AVFoundation
import SwiftUI

private let appDelegateSingleton = AppDelegate()

@main
struct MacOsMixerApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegateSingleton
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let mixerState = MixerState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "slider.vertical.3",
                                 accessibilityDescription: "Audio Mixer") {
                button.image = img
            } else {
                button.title = "Mix"
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MixerPopoverView()
                .environment(mixerState)
        )

        requestAudioPermission()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func requestAudioPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            NSLog("[MacOsMixer] Microphone access already granted")
            mixerState.micPermissionGranted = true
        case .notDetermined:
            NSLog("[MacOsMixer] Requesting microphone access...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.mixerState.micPermissionGranted = granted
                    if granted {
                        NSLog("[MacOsMixer] Microphone access granted")
                    } else {
                        NSLog("[MacOsMixer] Microphone access DENIED")
                    }
                }
            }
        case .denied, .restricted:
            NSLog("[MacOsMixer] Microphone access denied/restricted")
            mixerState.micPermissionGranted = false
        @unknown default:
            break
        }
    }
}
