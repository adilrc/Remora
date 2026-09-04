internal import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let overlay: OverlayController
  private let updates: UpdateController
  private var statusItem: NSStatusItem?

  init(overlay: OverlayController, updates: UpdateController) {
    self.overlay = overlay
    self.updates = updates
  }

  func start() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if let icon = NSImage(named: "MenuBarIcon") {
        icon.isTemplate = true
        icon.accessibilityDescription = "Remora"
        button.image = icon
      } else {
        button.title = "Remora"
      }
      button.toolTip = "Remora"
    }
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item

    overlay.onStateChange = { [weak self] in
      self?.rebuildMenu()
    }
    rebuildMenu()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu()
  }
}

// MARK: - Private functionality

private extension StatusItemController {
  func rebuildMenu() {
    guard let menu = statusItem?.menu else { return }
    menu.removeAllItems()

    menu.addItem(makeItem(
      title: overlay.isHUDVisible ? "Hide HUD" : "Show HUD",
      action: #selector(toggleHUD(_:))
    ))
    menu.addItem(makeItem(
      title: overlay.isHUDDetached ? "Attach HUD to Window" : "Detach HUD from Window",
      action: #selector(toggleDetached(_:))
    ))
    if !overlay.isFollowingActiveWindow {
      menu.addItem(makeItem(title: "Attach to Active Window", action: #selector(attachToActiveWindow(_:))))
    }

    if !AccessibilityPermission.isGranted {
      menu.addItem(.separator())
      menu.addItem(makeItem(
        title: "\(AccessibilityPermission.grantActionTitle)…",
        action: #selector(showOnboarding(_:))
      ))
    }

    menu.addItem(.separator())
    menu.addItem(makeItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ","))
    menu.addItem(makeItem(title: "About \(AppInfo.name)", action: #selector(showAbout(_:))))
    menu.addItem(updates.makeMenuItem())
    menu.addItem(.separator())
    menu.addItem(makeItem(title: "Quit \(AppInfo.name)", action: #selector(quit(_:)), keyEquivalent: "q"))
  }

  func makeItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
  }

  @objc func toggleHUD(_ sender: Any?) {
    overlay.toggleHUD()
  }

  @objc func toggleDetached(_ sender: Any?) {
    overlay.toggleDetached()
  }

  @objc func attachToActiveWindow(_ sender: Any?) {
    overlay.attachToActiveWindow()
  }

  @objc func showOnboarding(_ sender: Any?) {
    overlay.showOnboarding()
  }

  @objc func openSettings(_ sender: Any?) {
    overlay.showSettings()
  }

  @objc func showAbout(_ sender: Any?) {
    overlay.showAbout()
  }

  @objc func quit(_ sender: Any?) {
    NSApp.terminate(nil)
  }
}
