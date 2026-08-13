import XCTest
@testable import SkillHub

final class AppPreferencesTests: XCTestCase {
    func testLegacyPreferencesMigrateWithoutOverwritingCurrentValues() throws {
        let suffix = UUID().uuidString
        let legacyDomain = "SkillHubTests.legacy.\(suffix)"
        let destinationDomain = "SkillHubTests.current.\(suffix)"
        guard let defaults = UserDefaults(suiteName: destinationDomain) else {
            return XCTFail("无法创建测试 UserDefaults")
        }
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: destinationDomain)
        }

        defaults.removePersistentDomain(forName: destinationDomain)
        defaults.setPersistentDomain(
            ["favoriteSkills": "legacy", "customDirs": "/legacy"],
            forName: legacyDomain
        )
        defaults.set("current", forKey: "favoriteSkills")

        AppPreferences.migrateLegacyBundleIfNeeded(
            defaults: defaults,
            destinationDomain: destinationDomain,
            legacyDomain: legacyDomain,
            currentDomain: destinationDomain
        )

        XCTAssertEqual(defaults.string(forKey: "favoriteSkills"), "current")
        XCTAssertEqual(defaults.string(forKey: "customDirs"), "/legacy")
    }
}
