import Foundation

/// Carries settings over from `local.paddock`, the bundle identifier Paddock had before its first public release.
enum SettingsMigration {
    static let legacyDomain = "local.paddock"

    /// The settings worth keeping, including where the user put the menu bar icon. `didSetUpLoginItem` is left out on
    /// purpose: the login item belongs to the old identity, so the new one registers its own on its first launch from
    /// Applications.
    static let keys = [
        "keepAlive",
        "startServerWhenOpened",
        "ownedServer",
        "NSStatusItem Preferred Position Item-0",
        "NSWindow Frame ServerLog",
    ]

    static let doneKey = "migratedFromLocalPaddock"

    /// Copies the kept settings from `legacy` into `defaults` once, never overwriting a setting that already exists.
    static func migrate(legacy: [String: Any]?, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let legacy else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
    }
}
