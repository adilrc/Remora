internal import AppKit

/// The app is a menu-bar accessory, but its ordinary windows (Settings, onboarding) should behave
/// like a regular app: Dock icon, app switcher entry, main menu. This flips the activation policy
/// while any such window is on screen and back to accessory when the last one closes.
@MainActor
enum AppActivation {
  private static var visibleWindows: Set<ObjectIdentifier> = []

  /// Call before ordering `window` front.
  static func windowWillShow(_ window: NSWindow) {
    visibleWindows.insert(ObjectIdentifier(window))
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Call from the window delegate’s `windowWillClose`.
  static func windowWillClose(_ window: NSWindow) {
    visibleWindows.remove(ObjectIdentifier(window))
    guard visibleWindows.isEmpty else { return }
    // Back to a menu-bar-only process; macOS hands focus to the next app.
    NSApp.setActivationPolicy(.accessory)
  }
}
