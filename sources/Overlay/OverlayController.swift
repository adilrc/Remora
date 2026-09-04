internal import AppKit

@MainActor
final class OverlayController {
  private let settings = AppSettings.shared
  private let tracker = FrontmostWindowTracker()
  private let sampler = ProcessMetricsSampler()
  private let launchTimer = ApplicationLaunchTimer()
  private let hudWindow = HUDWindow()
  private let hotkeyMonitor = HotkeyMonitor()
  private let settingsWindow = SettingsWindowController()
  private let onboardingWindow = OnboardingWindowController()
  private let aboutWindow = AboutWindowController()

  private var settleTimer: Timer?
  private var metricsTimer: Timer?
  private var latestTarget: FrontmostWindowTracker.Target?
  private var latestMetrics = ProcessMetrics()
  private var lastSnapshot: HUDSnapshot?
  private var hudVisible = true

  var isHUDVisible: Bool { hudVisible }
  var isHUDDetached: Bool { settings.isDetached }

  var onStateChange: (() -> Void)?

  func start() {
    settings.startMonitoring()
    sampler.refreshInterval = settings.refreshInterval.seconds
    launchTimer.setVisuallyCompleteEnabled(settings.showsVisuallyComplete)
    launchTimer.start()

    hudWindow.onHideRequested = { [weak self] in self?.hideHUD() }
    hudWindow.onMetricToggleRequested = { [weak self] metric in self?.toggleMetric(metric) }
    hudWindow.onMetricOrderChanged = { [weak self] visibleOrder in self?.metricOrderChanged(visibleOrder) }
    hudWindow.onDetachToggleRequested = { [weak self] in self?.toggleDetached() }
    hudWindow.onAttachToActiveWindowRequested = { [weak self] in self?.attachToActiveWindow() }
    hudWindow.onExcludeCurrentAppRequested = { [weak self] in self?.excludeCurrentApp() }
    hudWindow.onSettingsRequested = { [weak self] in self?.showSettings() }
    hudWindow.onSnapped = { [weak self] anchor in self?.settings.position = anchor }
    hudWindow.onDetachedOriginChanged = { [weak self] origin in self?.settings.detachedOrigin = origin }
    settingsWindow.onShowOnboarding = { [weak self] in self?.showOnboarding() }
    onboardingWindow.onVisibilityChanged = { [weak self] _ in self?.render() }

    tracker.onChange = { [weak self] target in
      guard let self else { return }
      let previousPID = latestTarget?.pid
      latestTarget = target
      if target?.pid != previousPID {
        // A new app: show its memory right away instead of waiting for the next tick.
        refreshMetrics()
      }
      render()
    }
    applyTrackingSettings()
    tracker.start()

    hotkeyMonitor.onPressed = { [weak self] in self?.toggleHUD() }
    hotkeyMonitor.setShortcut(settings.toggleShortcut)

    settings.observe(self) { [weak self] change in
      self?.settingsChanged(change)
    }

    launchTimer.onUpdate = { [weak self] in self?.render() }
    scheduleMetricsTimer()
    refreshMetrics()
    render()
  }

  func stop() {
    settleTimer?.invalidate()
    metricsTimer?.invalidate()
    tracker.stop()
    launchTimer.stop()
    settings.removeObserver(self)
    hotkeyMonitor.setShortcut(nil)
    hudWindow.orderOut(nil)
  }

  func toggleHUD() {
    hudVisible.toggle()
    render()
    onStateChange?()
  }

  func hideHUD() {
    guard hudVisible else { return }
    hudVisible = false
    render()
    onStateChange?()
  }

  func toggleDetached() {
    settings.isDetached.toggle()
  }

  var isFollowingActiveWindow: Bool { settings.followsActiveWindow }

  func attachToActiveWindow() {
    tracker.attachToActiveApplication()
  }

  /// Adds the app the HUD is showing to the excluded list; the HUD hides on it from now on.
  func excludeCurrentApp() {
    guard let identifier = latestTarget?.bundleIdentifier else { return }
    settings.excludedBundleIdentifiers.append(identifier)
  }

  func showSettings() {
    settingsWindow.show()
  }

  func showOnboarding() {
    onboardingWindow.show()
  }

  func showAbout() {
    aboutWindow.show()
  }
}

// MARK: - Private functionality

private extension OverlayController {
  func refreshMetrics() {
    guard let pid = latestTarget?.pid else {
      latestMetrics = ProcessMetrics()
      return
    }
    latestMetrics = sampler.sample(
      pid: pid,
      bundleIdentifier: latestTarget?.bundleIdentifier,
      bundlePath: latestTarget?.bundleURL?.path
    )
  }

  func settingsChanged(_ change: AppSettings.Change) {
    switch change {
    case .toggleShortcut:
      hotkeyMonitor.setShortcut(settings.toggleShortcut)

    case .refreshInterval:
      sampler.refreshInterval = settings.refreshInterval.seconds
      scheduleMetricsTimer()

    case .showsVisuallyComplete:
      launchTimer.setVisuallyCompleteEnabled(settings.showsVisuallyComplete)
      if settings.showsVisuallyComplete {
        ScreenRecordingPermission.promptIfNeeded()
      }

    case .followsActiveWindow, .excludedBundleIdentifiers:
      applyTrackingSettings()
      tracker.refresh()
      onStateChange?()

    case .isDetached:
      detachedDidChange()

    case .position:
      if !settings.isDetached, let target = latestTarget {
        hudWindow.animateAttach(to: target.cocoaFrame, anchor: settings.position)
      }

    default:
      break
    }
    render()
  }

  /// Samples exactly once per refresh interval; rates are computed between consecutive samples.
  func scheduleMetricsTimer() {
    metricsTimer?.invalidate()
    let interval = settings.refreshInterval.seconds
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshMetrics()
        self?.render()
      }
    }
    timer.tolerance = min(0.5, interval * 0.05)
    metricsTimer = timer
  }

  /// Keeps easing the HUD toward its anchor at 30 Hz only while it is still moving.
  func updateSettleTimer(isSettled: Bool) {
    if isSettled {
      settleTimer?.invalidate()
      settleTimer = nil
    } else if settleTimer == nil {
      settleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
        Task { @MainActor in
          guard let self, let target = self.latestTarget, !self.settings.isDetached else {
            self?.updateSettleTimer(isSettled: true)
            return
          }
          let settled = self.hudWindow.follow(hostFrame: target.cocoaFrame, anchor: self.settings.position)
          self.updateSettleTimer(isSettled: settled)
        }
      }
    }
  }

  func applyTrackingSettings() {
    tracker.isFollowingActiveWindow = settings.followsActiveWindow
    tracker.excludedBundleIdentifiers = Set(settings.excludedBundleIdentifiers)
  }

  func detachedDidChange() {
    if settings.isDetached {
      // Start detached life exactly where the HUD currently sits.
      settings.detachedOrigin = hudWindow.frame.origin
    } else if let target = latestTarget {
      hudWindow.animateAttach(to: target.cocoaFrame, anchor: settings.position)
    }
    onStateChange?()
  }

  func toggleMetric(_ metric: HUDMetric) {
    switch metric {
    case .cpu: settings.showsCPU.toggle()
    case .memory: settings.showsMemory.toggle()
    case .energyImpact: settings.showsEnergyImpact.toggle()
    case .twelveHourPower: settings.showsTwelveHourPower.toggle()
    case .launchTimer: settings.showsLaunchTimer.toggle()
    case .timeToInteractive: settings.showsTimeToInteractive.toggle()
    case .visuallyComplete: settings.showsVisuallyComplete.toggle()
    }
  }

  func isShown(_ metric: HUDMetric) -> Bool {
    switch metric {
    case .cpu: settings.showsCPU
    case .memory: settings.showsMemory
    case .energyImpact: settings.showsEnergyImpact
    case .twelveHourPower: settings.showsTwelveHourPower
    case .launchTimer: settings.showsLaunchTimer
    case .timeToInteractive: settings.showsTimeToInteractive
    case .visuallyComplete: settings.showsVisuallyComplete
    }
  }

  func metricOrderChanged(_ visibleOrder: [HUDMetric]) {
    let hiddenOrder = settings.metricOrder.filter { !visibleOrder.contains($0) }
    settings.metricOrder = visibleOrder + hiddenOrder
    render()
  }

  func render() {
    // The onboarding window owns the screen while it is up; a HUD nagging about the same
    // permission next to it is noise.
    guard hudVisible, !onboardingWindow.isShowing, settings.hasVisibleMetric, let target = latestTarget else {
      lastSnapshot = nil
      hudWindow.orderOut(nil)
      return
    }

    let snapshot = HUDSnapshot(
      appName: target.appName,
      appIcon: target.appIcon,
      metrics: latestMetrics,
      launchDuration: launchTimer.duration(for: target.pid),
      timeToInteractiveDuration: launchTimer.timeToInteractiveDuration(for: target.pid),
      visuallyCompleteDuration: launchTimer.visuallyCompleteDuration(for: target.pid),
      visibleMetrics: settings.metricOrder.filter(isShown),
      thresholds: settings.thresholds,
      isDetached: settings.isDetached,
      followsActiveWindow: settings.followsActiveWindow,
      missingAccessibility: !AccessibilityPermission.isGranted,
      missingScreenRecording: settings.showsVisuallyComplete
        && !ScreenRecordingPermission.isGranted
    )

    if snapshot != lastSnapshot {
      lastSnapshot = snapshot
      hudWindow.update(snapshot: snapshot)
    }

    if settings.isDetached {
      hudWindow.placeDetached(at: settings.detachedOrigin)
      updateSettleTimer(isSettled: true)
    } else {
      let settled = hudWindow.follow(hostFrame: target.cocoaFrame, anchor: settings.position)
      updateSettleTimer(isSettled: settled)
    }
    if !hudWindow.isVisible {
      hudWindow.orderFrontRegardless()
    }
  }
}
