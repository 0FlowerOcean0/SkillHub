import Foundation

enum AppPreferences {
    static let legacyBundleIdentifier = "com.skillhub.app"
    static let currentBundleIdentifier = "io.github.0flowerocean0.SkillHub"
    private static let migrationMarker = "didMigratePreferencesFromComSkillhubApp"

    static func migrateLegacyBundleIfNeeded(
        defaults: UserDefaults = .standard,
        destinationDomain: String? = Bundle.main.bundleIdentifier,
        legacyDomain: String = legacyBundleIdentifier,
        currentDomain: String = currentBundleIdentifier
    ) {
        guard destinationDomain == currentDomain,
              defaults.object(forKey: migrationMarker) == nil else { return }

        let existing = defaults.persistentDomain(forName: destinationDomain ?? "") ?? [:]
        if let legacy = defaults.persistentDomain(forName: legacyDomain) {
            for (key, value) in legacy where existing[key] == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationMarker)
    }
}
