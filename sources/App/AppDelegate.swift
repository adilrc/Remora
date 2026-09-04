internal import AppKit

@MainActor
final class AppDelegate: NSObject {
  private let overlayController = OverlayController()
  private let updateController = UpdateController()
  private var statusItemController: StatusItemController?
}

extension AppDelegate: NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Shown whenever a window makes the app regular (Dock icon visible).
    NSApp.mainMenu = MainMenu.make(
      showAbout: { [weak self] in self?.overlayController.showAbout() },
      showSettings: { [weak self] in self?.overlayController.showSettings() }
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Metric order briefly lived in UserDefaults before moving to the configuration file.
    UserDefaults.standard.removeObject(forKey: "hud.metricOrder")

    let statusItem = StatusItemController(overlay: overlayController, updates: updateController)
    statusItemController = statusItem
    statusItem.start()
    overlayController.start()

    // `-ShowOnboarding YES` forces the onboarding window, which is handy while working on it.
    // The resume flag is left by the onboarding itself when it relaunches for Screen Recording.
    let resumeOnboarding = UserDefaults.standard.bool(forKey: OnboardingWindowController.resumeAfterRelaunchKey)
    UserDefaults.standard.removeObject(forKey: OnboardingWindowController.resumeAfterRelaunchKey)
    if !AccessibilityPermission.isGranted || resumeOnboarding || UserDefaults.standard.bool(forKey: "ShowOnboarding") {
      overlayController.showOnboarding()
    } else if !UserDefaults.standard.bool(forKey: "didOpenSettingsOnce") {
      UserDefaults.standard.set(true, forKey: "didOpenSettingsOnce")
      overlayController.showSettings()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    overlayController.stop()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    overlayController.handleReopen()
    return false
  }
}
