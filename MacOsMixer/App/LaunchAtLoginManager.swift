import Foundation
import ServiceManagement

/// Manages "Launch at Login" using SMAppService (macOS 13+) with a LaunchAgent
/// plist as fallback for developer builds not running from an app bundle.
enum LaunchAtLoginManager {

    private static var agentLabel: String {
        Bundle.main.bundleIdentifier ?? "com.macmixer.audiomixer"
    }
    private static var agentPlistURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(agentLabel).plist")
    }

    // MARK: - Public

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return agentPlistExists()
    }

    static func setEnabled(_ enabled: Bool) {
        // Try the modern SMAppService API first.
        let smsResult = setSMAppService(enabled)
        if smsResult {
            // SMAppService succeeded — clean up any legacy LaunchAgent.
            if enabled { removeLaunchAgent() }
            return
        }
        // Fallback: LaunchAgent plist (works for developer builds run outside .app bundle).
        if enabled {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    // MARK: - SMAppService

    @discardableResult
    private static func setSMAppService(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            NSLog("[LaunchAtLogin] SMAppService %@", enabled ? "registered" : "unregistered")
            return true
        } catch {
            NSLog("[LaunchAtLogin] SMAppService failed (%@), using LaunchAgent fallback", error.localizedDescription)
            return false
        }
    }

    // MARK: - LaunchAgent fallback

    private static func installLaunchAgent() {
        // Use the running executable's path so this works for both debug and
        // release builds. On a deployed build this will be inside the .app bundle.
        let execPath = Bundle.main.executablePath
            ?? "/Applications/MacOsMixer.app/Contents/MacOS/MacOs Mixer"

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua"
        ]

        do {
            let launchAgentsDir = agentPlistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: launchAgentsDir,
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                format: .xml, options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
            NSLog("[LaunchAtLogin] LaunchAgent installed at %@", agentPlistURL.path)

            // Tell launchd to load the new agent immediately.
            launchctl("load", agentPlistURL.path)
        } catch {
            NSLog("[LaunchAtLogin] Failed to install LaunchAgent: %@", error.localizedDescription)
        }
    }

    private static func removeLaunchAgent() {
        guard agentPlistExists() else { return }
        launchctl("unload", agentPlistURL.path)
        try? FileManager.default.removeItem(at: agentPlistURL)
        NSLog("[LaunchAtLogin] LaunchAgent removed")
    }

    private static func agentPlistExists() -> Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    @discardableResult
    private static func launchctl(_ verb: String, _ path: String) -> Int32 {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = [verb, "-w", path]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
