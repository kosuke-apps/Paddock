import Foundation
import ServiceManagement

/// Paddock's settings, stored in its user defaults (`defaults read dev.kosuke.paddock`).
@MainActor
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Takes effect the next time the server starts.
    var keepAlive: KeepAlive {
        get { defaults.string(forKey: "keepAlive").flatMap(KeepAlive.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "keepAlive") }
    }

    /// Off by default. Paddock opens at login, so this is how the server comes on at login.
    var startServerWhenOpened: Bool {
        get { defaults.bool(forKey: "startServerWhenOpened") }
        set { defaults.set(newValue, forKey: "startServerWhenOpened") }
    }

    fileprivate var didSetUpLoginItem: Bool {
        get { defaults.bool(forKey: "didSetUpLoginItem") }
        set { defaults.set(newValue, forKey: "didSetUpLoginItem") }
    }
}

/// Opening Paddock at login, through the system's login items.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Adds Paddock to the login items the first time it runs from an Applications folder, so its icon is there
    /// after every login. A copy run from the build folder is left out: a login item pointing at a build output
    /// breaks as soon as the folder changes. After the first time, the menu setting is respected.
    static func setUpOnFirstLaunch(_ preferences: Preferences) {
        guard !preferences.didSetUpLoginItem, isInApplicationsFolder else { return }
        preferences.didSetUpLoginItem = true
        try? SMAppService.mainApp.register()
    }

    private static var isInApplicationsFolder: Bool {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return folder == "/Applications" || folder == home
    }
}
