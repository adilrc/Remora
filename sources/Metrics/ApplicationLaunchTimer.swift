internal import AppKit
internal import ApplicationServices
private import Darwin

@MainActor
/// Records launch milestones for applications started while Remora is running.
/// Launches that predate Remora cannot be measured because Window Server does not expose historical creation times.
final class ApplicationLaunchTimer {
  private typealias RemoteNotificationRegistration = @convention(c) (
    AXObserver,
    AXUIElement,
    CFString,
    UnsafeMutableRawPointer?
  ) -> AXError

  private static let remoteNotificationRegistration: RemoteNotificationRegistration? = {
    // This SPI keeps Chromium accessibility trees live for remote observers. It is optional and
    // resolved dynamically because it is not exported on every macOS release.
    let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    let handle = dlopen(path, RTLD_LAZY)
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    for symbolName in [
      "_AXObserverAddNotificationAndCheckRemote",
      "AXObserverAddNotificationAndCheckRemote",
    ] {
      let symbol = handle.flatMap { dlsym($0, symbolName) } ?? dlsym(defaultHandle, symbolName)
      if let symbol {
        return unsafeBitCast(symbol, to: RemoteNotificationRegistration.self)
      }
    }
    return nil
  }()

  private struct PendingLaunch {
    var startedAt: Date
    var isElectron: Bool
  }

  private let maximumTrackingDuration: TimeInterval = 60
  private var pendingLaunches: [pid_t: PendingLaunch] = [:]
  private var pendingInteractiveLaunches: [pid_t: PendingLaunch] = [:]
  private var launchDurations: [pid_t: TimeInterval] = [:]
  private var timeToInteractiveDurations: [pid_t: TimeInterval] = [:]
  private var accessibilityObservers: [pid_t: AXObserver] = [:]
  private var accessibilityElements: [pid_t: AXUIElement] = [:]
  private var completedChromiumAccessibilityActivation: Set<pid_t> = []
  private var nextAccessibilityObserverAttemptDate: [pid_t: Date] = [:]
  private var nextChromiumAccessibilityActivationDate: [pid_t: Date] = [:]
  private var workspaceObservers: [NSObjectProtocol] = []

  /// Called after each measurement pass while a launch is being tracked.
  var onUpdate: (() -> Void)?

  private var pollTimer: Timer?

  func start() {
    guard workspaceObservers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter

    let willLaunchObserver = center.addObserver(
      forName: NSWorkspace.willLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      guard application.activationPolicy == .regular,
            application.processIdentifier > 0
      else { return }
      let pid = application.processIdentifier
      let startedAt = application.launchDate ?? Date()
      MainActor.assumeIsolated {
        self?.applicationWillLaunch(
          pid: pid,
          startedAt: startedAt,
          isElectron: Self.isElectronApplication(application)
        )
      }
    }
    let launchObserver = center.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      guard application.activationPolicy == .regular,
            application.processIdentifier > 0
      else { return }
      let pid = application.processIdentifier
      let startedAt = application.launchDate ?? Date()
      MainActor.assumeIsolated {
        self?.applicationDidLaunch(
          pid: pid,
          startedAt: startedAt,
          isElectron: Self.isElectronApplication(application)
        )
      }
    }
    let terminationObserver = center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return
      }
      let pid = application.processIdentifier
      MainActor.assumeIsolated {
        self?.applicationDidTerminate(pid: pid)
      }
    }
    workspaceObservers = [willLaunchObserver, launchObserver, terminationObserver]
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    workspaceObservers.removeAll()
    for pid in Array(accessibilityObservers.keys) {
      tearDownAccessibilityObserver(for: pid)
    }
    accessibilityElements.removeAll()
    completedChromiumAccessibilityActivation.removeAll()
    nextAccessibilityObserverAttemptDate.removeAll()
    nextChromiumAccessibilityActivationDate.removeAll()
    pendingLaunches.removeAll()
    pendingInteractiveLaunches.removeAll()
    launchDurations.removeAll()
    timeToInteractiveDurations.removeAll()
  }

  func refresh(now: Date = Date()) {
    refreshLaunchDurations(now: now)
    refreshTimeToInteractiveDurations(now: now)
    updatePolling()
  }

  /// Runs a 10 Hz poll only while there is a pending launch, so an idle app costs nothing.
  private func updatePolling() {
    let isTracking = !pendingLaunches.isEmpty || !pendingInteractiveLaunches.isEmpty
    if isTracking, pollTimer == nil {
      let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        Task { @MainActor in
          self?.refresh()
          self?.onUpdate?()
        }
      }
      timer.tolerance = 0.02
      pollTimer = timer
    } else if !isTracking, let pollTimer {
      pollTimer.invalidate()
      self.pollTimer = nil
      onUpdate?()
    }
  }

  func duration(for pid: pid_t) -> TimeInterval? {
    launchDurations[pid]
  }

  func timeToInteractiveDuration(for pid: pid_t) -> TimeInterval? {
    timeToInteractiveDurations[pid]
  }


}

// MARK: - Private functionality

private extension ApplicationLaunchTimer {
  func refreshLaunchDurations(now: Date) {
    var completedLaunches: [(pid: pid_t, duration: TimeInterval)] = []
    var expiredPIDs: [pid_t] = []
    for (pid, launch) in pendingLaunches {
      let elapsed = now.timeIntervalSince(launch.startedAt)
      if elapsed > maximumTrackingDuration {
        expiredPIDs.append(pid)
      } else if CGWindowList.primaryWindowFrame(pid: pid) != nil {
        completedLaunches.append((pid, max(elapsed, 0)))
      }
    }
    expiredPIDs.forEach { pendingLaunches.removeValue(forKey: $0) }
    for launch in completedLaunches {
      launchDurations[launch.pid] = launch.duration
      pendingLaunches.removeValue(forKey: launch.pid)
    }
  }

  func refreshTimeToInteractiveDurations(now: Date) {
    var completedLaunches: [(pid: pid_t, duration: TimeInterval)] = []
    var expiredPIDs: [pid_t] = []
    for (pid, launch) in pendingInteractiveLaunches {
      let elapsed = now.timeIntervalSince(launch.startedAt)
      if elapsed > maximumTrackingDuration {
        expiredPIDs.append(pid)
        continue
      }

      attachAccessibilityObserver(to: pid, now: now)
      guard CGWindowList.primaryWindowFrame(pid: pid) != nil,
            hasInteractiveAccessibilityElement(pid: pid, now: now)
      else { continue }
      completedLaunches.append((pid, max(elapsed, 0)))
    }

    for pid in expiredPIDs {
      pendingInteractiveLaunches.removeValue(forKey: pid)
      tearDownAccessibilityObserver(for: pid)
    }
    for launch in completedLaunches {
      timeToInteractiveDurations[launch.pid] = launch.duration
      pendingInteractiveLaunches.removeValue(forKey: launch.pid)
      tearDownAccessibilityObserver(for: launch.pid)
    }
  }

  func applicationWillLaunch(pid: pid_t, startedAt: Date, isElectron: Bool) {
    guard !isTrackingLaunch(pid: pid) else { return }
    tearDownAccessibilityObserver(for: pid)
    let launch = PendingLaunch(startedAt: startedAt, isElectron: isElectron)
    pendingLaunches[pid] = launch
    pendingInteractiveLaunches[pid] = launch
    launchDurations.removeValue(forKey: pid)
    timeToInteractiveDurations.removeValue(forKey: pid)
    refresh()
  }

  func applicationDidLaunch(pid: pid_t, startedAt: Date, isElectron: Bool) {
    guard isTrackingLaunch(pid: pid) else {
      applicationWillLaunch(pid: pid, startedAt: startedAt, isElectron: isElectron)
      return
    }

    if var launch = pendingLaunches[pid] {
      launch.startedAt = startedAt
      launch.isElectron = launch.isElectron || isElectron
      pendingLaunches[pid] = launch
    }
    if var launch = pendingInteractiveLaunches[pid] {
      launch.startedAt = startedAt
      launch.isElectron = launch.isElectron || isElectron
      pendingInteractiveLaunches[pid] = launch
    }
    refresh()
  }

  func applicationDidTerminate(pid: pid_t) {
    pendingLaunches.removeValue(forKey: pid)
    pendingInteractiveLaunches.removeValue(forKey: pid)
    launchDurations.removeValue(forKey: pid)
    timeToInteractiveDurations.removeValue(forKey: pid)
    tearDownAccessibilityObserver(for: pid)
  }

  func isTrackingLaunch(pid: pid_t) -> Bool {
    pendingLaunches[pid] != nil
      || pendingInteractiveLaunches[pid] != nil
      || launchDurations[pid] != nil
      || timeToInteractiveDurations[pid] != nil
  }

  func attachAccessibilityObserver(to pid: pid_t, now: Date) {
    guard AccessibilityPermission.isGranted else { return }

    let appElement: AXUIElement
    if let existingElement = accessibilityElements[pid] {
      appElement = existingElement
    } else {
      appElement = AXUIElementCreateApplication(pid)
      accessibilityElements[pid] = appElement
    }
    enableChromiumAccessibilityIfPossible(for: pid, appElement: appElement, now: now)
    guard accessibilityObservers[pid] == nil else { return }
    if let nextAttemptDate = nextAccessibilityObserverAttemptDate[pid], now < nextAttemptDate {
      return
    }
    nextAccessibilityObserverAttemptDate[pid] = now.addingTimeInterval(0.25)

    var observer: AXObserver?
    let createError = AXObserverCreate(pid, launchTimerAXObserverCallback, &observer)
    guard createError == .success, let observer else { return }

    let refcon = Unmanaged.passUnretained(self).toOpaque()
    let notifications = [
      kAXFocusedUIElementChangedNotification as CFString,
      kAXFocusedWindowChangedNotification as CFString,
      kAXWindowCreatedNotification as CFString,
    ]
    let errors = notifications.map {
      addAccessibilityNotification($0, observer: observer, element: appElement, refcon: refcon)
    }
    let registered = errors.contains { $0 == .success || $0 == .notificationAlreadyRegistered }
    guard registered else { return }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    accessibilityObservers[pid] = observer
    nextAccessibilityObserverAttemptDate.removeValue(forKey: pid)
  }

  func tearDownAccessibilityObserver(for pid: pid_t) {
    if let observer = accessibilityObservers.removeValue(forKey: pid) {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    accessibilityElements.removeValue(forKey: pid)
    completedChromiumAccessibilityActivation.remove(pid)
    nextAccessibilityObserverAttemptDate.removeValue(forKey: pid)
    nextChromiumAccessibilityActivationDate.removeValue(forKey: pid)
  }

  func hasInteractiveAccessibilityElement(pid: pid_t, now: Date) -> Bool {
    guard AccessibilityPermission.isGranted else { return false }
    if accessibilityElements[pid] == nil {
      attachAccessibilityObserver(to: pid, now: now)
    }
    guard let appElement = accessibilityElements[pid] else { return false }
    enableChromiumAccessibilityIfPossible(for: pid, appElement: appElement, now: now)
    if let focusedElement: AXUIElement = axValue(
      appElement,
      attribute: kAXFocusedUIElementAttribute
    ), isKeyboardFocusedTextInput(focusedElement) {
      return true
    }
    return false
  }

  func isKeyboardFocusedTextInput(_ element: AXUIElement) -> Bool {
    let isFocused: Bool? = axValue(element, attribute: kAXFocusedAttribute)
    guard isFocused == true else { return false }

    let role: String = axValue(element, attribute: kAXRoleAttribute) ?? ""
    let textInputRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String]
    guard textInputRoles.contains(role) else { return false }

    let isEnabled: Bool? = axValue(element, attribute: kAXEnabledAttribute)
    return isEnabled != false
  }

  func enableChromiumAccessibilityIfPossible(
    for pid: pid_t,
    appElement: AXUIElement,
    now: Date
  ) {
    guard !completedChromiumAccessibilityActivation.contains(pid) else { return }
    if let nextAttemptDate = nextChromiumAccessibilityActivationDate[pid], now < nextAttemptDate {
      return
    }
    nextChromiumAccessibilityActivationDate[pid] = now.addingTimeInterval(0.25)

    // Chromium enables its platform accessibility mode when an assistive client probes the
    // application role. Accessibility Inspector performs this probe as soon as it attaches.
    let _: String? = axValue(appElement, attribute: kAXRoleAttribute)
    let manualError = AXUIElementSetAttributeValue(
      appElement,
      "AXManualAccessibility" as CFString,
      true as CFTypeRef
    )
    if manualError == .success {
      completedChromiumAccessibilityActivation.insert(pid)
      nextChromiumAccessibilityActivationDate.removeValue(forKey: pid)
      return
    }
    guard manualError == .attributeUnsupported else { return }

    let enhancedError = AXUIElementSetAttributeValue(
      appElement,
      "AXEnhancedUserInterface" as CFString,
      true as CFTypeRef
    )
    if enhancedError == .success {
      completedChromiumAccessibilityActivation.insert(pid)
      nextChromiumAccessibilityActivationDate.removeValue(forKey: pid)
    } else if enhancedError == .attributeUnsupported,
              pendingInteractiveLaunches[pid]?.isElectron != true {
      // Native applications do not need Chromium activation. Electron can transiently report
      // both attributes as unsupported while its custom NSApplication subclass is initializing.
      completedChromiumAccessibilityActivation.insert(pid)
      nextChromiumAccessibilityActivationDate.removeValue(forKey: pid)
    }
  }

  func handleAccessibilityNotification() {
    refresh()
  }

  func addAccessibilityNotification(
    _ notification: CFString,
    observer: AXObserver,
    element: AXUIElement,
    refcon: UnsafeMutableRawPointer?
  ) -> AXError {
    if let registration = Self.remoteNotificationRegistration {
      return registration(observer, element, notification, refcon)
    }
    return AXObserverAddNotification(observer, element, notification, refcon)
  }

  static func isElectronApplication(_ application: NSRunningApplication) -> Bool {
    guard let bundleURL = application.bundleURL else { return false }
    let frameworkURL = bundleURL.appendingPathComponent(
      "Contents/Frameworks/Electron Framework.framework",
      isDirectory: true
    )
    return FileManager.default.fileExists(atPath: frameworkURL.path)
  }
}

private func launchTimerAXObserverCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let timer = Unmanaged<ApplicationLaunchTimer>.fromOpaque(refcon).takeUnretainedValue()
  DispatchQueue.main.async {
    timer.handleAccessibilityNotification()
  }
}
