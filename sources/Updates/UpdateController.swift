internal import AppKit
internal import Sparkle

/// Owns the Sparkle updater. Checks run daily in the background (`SUEnableAutomaticChecks` in
/// Info.plist); the feed and public key live there too, and the release script keeps the appcast current.
@MainActor
final class UpdateController {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  /// A menu item wired to Sparkle, which enables and disables it as a check runs.
  func makeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    item.target = controller
    return item
  }
}
