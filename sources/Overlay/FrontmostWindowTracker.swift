import AppKit
import ApplicationServices

@MainActor
final class FrontmostWindowTracker {
  struct Target: Equatable {
    var pid: pid_t
    var bundleIdentifier: String?
    var appName: String
    var appIcon: NSImage?
    var bundleURL: URL?
    var cocoaFrame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.pid == rhs.pid
        && lhs.bundleIdentifier == rhs.bundleIdentifier
        && lhs.appName == rhs.appName
        && lhs.cocoaFrame == rhs.cocoaFrame
    }
  }

  var onChange: ((Target?) -> Void)?

  /// When false the tracked app is locked until `attachToActiveApplication()` or it quits.
  var isFollowingActiveWindow = true {
    didSet { if isFollowingActiveWindow { lockedApplication = nil } }
  }

  /// Apps the HUD never shows on.
  var excludedBundleIdentifiers: Set<String> = []

  private var lockedApplication: NSRunningApplication?
  private var fallbackTimer: Timer?

  private var lastOwnApp: NSRunningApplication?
  private var observer: AXObserver?
  private var observedPID: pid_t?
  private var observedAppElement: AXUIElement?
  private var observedWindow: AXUIElement?
  private var workspaceObservers: [NSObjectProtocol] = []

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    let names: [NSNotification.Name] = [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didDeactivateApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
    ]
    for name in names {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          self?.refresh()
        }
      }
      workspaceObservers.append(token)
    }
    // Window geometry arrives through AX notifications; this only catches apps that never post
    // them and the window-list fallback used without the Accessibility permission.
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    timer.tolerance = 0.25
    fallbackTimer = timer
    refresh()
  }

  func stop() {
    for token in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    workspaceObservers.removeAll()
    fallbackTimer?.invalidate()
    fallbackTimer = nil
    tearDownObserver()
  }

  func refresh() {
    let target = currentTarget()
    onChange?(target)
  }

  /// Locks onto the app that is active right now (only meaningful while not following).
  func attachToActiveApplication() {
    lockedApplication = frontmostOtherApplication()
    refresh()
  }

  private func currentTarget() -> Target? {
    guard let app = trackedApplication() else { return nil }
    if let identifier = app.bundleIdentifier, excludedBundleIdentifiers.contains(identifier) {
      if lockedApplication === app {
        lockedApplication = nil
      }
      return nil
    }
    attachObserver(to: app)

    let quartzFrame = primaryWindowQuartzFrame(for: app) ?? CGWindowList.primaryWindowFrame(pid: app.processIdentifier)
    guard let quartzFrame else { return nil }

    return Target(
      pid: app.processIdentifier,
      bundleIdentifier: app.bundleIdentifier,
      appName: app.localizedName ?? "Unknown",
      appIcon: app.icon,
      bundleURL: app.bundleURL,
      cocoaFrame: ScreenGeometry.cocoaRect(fromQuartz: quartzFrame)
    )
  }

  private func trackedApplication() -> NSRunningApplication? {
    guard !isFollowingActiveWindow else { return frontmostOtherApplication() }
    if let lockedApplication, !lockedApplication.isTerminated {
      return lockedApplication
    }
    lockedApplication = frontmostOtherApplication()
    return lockedApplication
  }

  private func frontmostOtherApplication() -> NSRunningApplication? {
    let ours = ProcessInfo.processInfo.processIdentifier
    if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ours, !app.isTerminated {
      lastOwnApp = app
      return app
    }
    if let lastOwnApp, !lastOwnApp.isTerminated, lastOwnApp.processIdentifier != ours {
      return lastOwnApp
    }
    return NSWorkspace.shared.runningApplications.first {
      $0.processIdentifier != ours && $0.activationPolicy == .regular && !$0.isTerminated
    }
  }

  private func primaryWindowQuartzFrame(for app: NSRunningApplication) -> CGRect? {
    guard AccessibilityPermission.isGranted else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return AXWindowPicker.primaryFrame(of: appElement)
  }

  private func attachObserver(to app: NSRunningApplication) {
    guard AccessibilityPermission.isGranted else { return }
    let pid = app.processIdentifier
    if observedPID == pid {
      if let observer, let observedAppElement {
        observePrimaryWindow(of: observedAppElement, observer: observer)
      }
      return
    }
    tearDownObserver()

    var observer: AXObserver?
    let error = AXObserverCreate(pid, axObserverCallback, &observer)
    guard error == .success, let observer else { return }

    let appElement = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
    AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)
    AXObserverAddNotification(observer, appElement, kAXApplicationHiddenNotification as CFString, refcon)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

    self.observer = observer
    self.observedPID = pid
    self.observedAppElement = appElement
    observePrimaryWindow(of: appElement, observer: observer)
  }

  private func observePrimaryWindow(of appElement: AXUIElement, observer: AXObserver) {
    let window = AXWindowPicker.primaryWindow(of: appElement)
    if let window, let observedWindow, CFEqual(window, observedWindow) {
      return
    }
    if let previous = observedWindow {
      AXObserverRemoveNotification(observer, previous, kAXWindowMovedNotification as CFString)
      AXObserverRemoveNotification(observer, previous, kAXWindowResizedNotification as CFString)
      AXObserverRemoveNotification(observer, previous, kAXUIElementDestroyedNotification as CFString)
    }

    observedWindow = window
    guard let window else { return }

    let refcon = Unmanaged.passUnretained(self).toOpaque()
    AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
    AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
    AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
  }

  func handleAXNotification() {
    if let observer, let observedAppElement {
      observePrimaryWindow(of: observedAppElement, observer: observer)
    }
    refresh()
  }

  private func tearDownObserver() {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    observedPID = nil
    observedAppElement = nil
    observedWindow = nil
  }
}

private enum AXWindowPicker {
  static let minimumWidth: CGFloat = 240
  static let minimumHeight: CGFloat = 160

  static func primaryFrame(of appElement: AXUIElement) -> CGRect? {
    guard let window = primaryWindow(of: appElement) else { return nil }
    return axWindowFrame(window)
  }

  static func primaryWindow(of appElement: AXUIElement) -> AXUIElement? {
    let focused: AXUIElement? = axValue(appElement, attribute: kAXFocusedWindowAttribute)
    if let focused, isPrimaryWindow(focused) {
      return focused
    }

    let main: AXUIElement? = axValue(appElement, attribute: kAXMainWindowAttribute)
    if let main, isPrimaryWindow(main) {
      return main
    }

    let windows: [AXUIElement] = axElements(appElement, attribute: kAXWindowsAttribute)
    return windows
      .filter(isPrimaryWindow)
      .max { lhs, rhs in
        area(axWindowFrame(lhs)) < area(axWindowFrame(rhs))
      }
  }

  static func isPrimaryWindow(_ window: AXUIElement) -> Bool {
    let role = axString(window, attribute: kAXRoleAttribute)
    if role == kAXPopoverRole as String
      || role == kAXMenuRole as String
      || role == kAXMenuBarRole as String
      || role == kAXHelpTagRole as String
    {
      return false
    }
    if !role.isEmpty, role != kAXWindowRole as String {
      return false
    }

    let subrole = axString(window, attribute: kAXSubroleAttribute)
    let auxiliarySubroles: Set<String> = [
      kAXFloatingWindowSubrole as String,
      kAXSystemFloatingWindowSubrole as String,
      kAXDialogSubrole as String,
      kAXSystemDialogSubrole as String,
    ]
    if auxiliarySubroles.contains(subrole) {
      return false
    }

    if axBool(window, attribute: kAXMinimizedAttribute) {
      return false
    }

    guard let frame = axWindowFrame(window) else { return false }
    return frame.width >= minimumWidth && frame.height >= minimumHeight
  }

  private static func area(_ frame: CGRect?) -> CGFloat {
    guard let frame else { return 0 }
    return frame.width * frame.height
  }
}

enum CGWindowList {
  static let minimumWidth: CGFloat = 240
  static let minimumHeight: CGFloat = 160

  static func primaryWindowFrame(pid: pid_t) -> CGRect? {
    guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }

    var best: CGRect?
    var bestArea: CGFloat = 0

    for info in infoList {
      guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
      let layer = info[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0 else { continue }
      let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
      guard alpha > 0.05 else { continue }
      guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            bounds.width >= minimumWidth,
            bounds.height >= minimumHeight
      else {
        continue
      }

      let area = bounds.width * bounds.height
      if area > bestArea {
        bestArea = area
        best = bounds
      }
    }
    return best
  }
}

private func axObserverCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let tracker = Unmanaged<FrontmostWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
  DispatchQueue.main.async {
    tracker.handleAXNotification()
  }
}
