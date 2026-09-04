internal import AppKit

/// The main menu used while the app is a regular app (Settings or onboarding on screen).
/// Without it, those windows would have no Close, Quit, or Edit commands.
@MainActor
enum MainMenu {
  static func make(showAbout: @escaping () -> Void, showSettings: @escaping () -> Void) -> NSMenu {
    let appName = AppInfo.name
    let mainMenu = NSMenu()

    let appMenu = NSMenu(title: appName)
    appMenu.addItem(actionItem(title: "About \(appName)", keyEquivalent: "", action: showAbout))
    appMenu.addItem(.separator())
    appMenu.addItem(actionItem(title: "Settings…", keyEquivalent: ",", action: showSettings))
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    mainMenu.addItem(submenu: appMenu)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    mainMenu.addItem(submenu: editMenu)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    mainMenu.addItem(submenu: windowMenu)
    NSApp.windowsMenu = windowMenu

    return mainMenu
  }
}

private extension NSMenu {
  func addItem(submenu: NSMenu) {
    let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    addItem(item)
  }
}

private extension MainMenu {
  /// A menu item that runs a closure. The target is retained through `representedObject`
  /// because `NSMenuItem.target` is weak.
  static func actionItem(title: String, keyEquivalent: String, action: @escaping () -> Void) -> NSMenuItem {
    let target = ClosureTarget(action: action)
    let item = NSMenuItem(title: title, action: #selector(ClosureTarget.perform(_:)), keyEquivalent: keyEquivalent)
    item.target = target
    item.representedObject = target
    return item
  }
}

@MainActor
private final class ClosureTarget: NSObject {
  private let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }

  @objc func perform(_ sender: Any?) {
    action()
  }
}
