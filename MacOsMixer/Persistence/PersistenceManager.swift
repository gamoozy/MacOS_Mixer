import Foundation
import os.log

private let logger = Logger(subsystem: "com.macmixer", category: "Persistence")

/// Stores and retrieves per-app audio preferences using UserDefaults.
///
/// Schema:  UserDefaults key "AppAudioPreferences" →
///   `[bundleID: { "volume": Float, "outputDeviceUID": String? }]`
final class PersistenceManager {

    private let defaults: UserDefaults
    private let storageKey = "AppAudioPreferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    func preference(for bundleID: String) -> AppPreference? {
        guard let dict = allPreferences()[bundleID] else { return nil }
        return dict
    }

    func allPreferences() -> [String: AppPreference] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: AppPreference].self, from: data)
        } catch {
            logger.error("Failed to decode preferences: \(error)")
            return [:]
        }
    }

    // MARK: - Write

    func save(preference: AppPreference, for bundleID: String) {
        var all = allPreferences()
        all[bundleID] = preference
        persist(all)
    }

    func removePreference(for bundleID: String) {
        var all = allPreferences()
        all.removeValue(forKey: bundleID)
        persist(all)
    }

    func clearAll() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Internal

    private func persist(_ prefs: [String: AppPreference]) {
        do {
            let data = try JSONEncoder().encode(prefs)
            defaults.set(data, forKey: storageKey)
        } catch {
            logger.error("Failed to encode preferences: \(error)")
        }
    }
}
