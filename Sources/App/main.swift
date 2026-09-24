import AppKit

// A menu bar app only: LSUIElement in Info.plist keeps it out of the Dock and the app switcher.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
