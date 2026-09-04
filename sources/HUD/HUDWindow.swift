internal import AppKit

struct HUDSnapshot: Equatable {
  var appName: String
  var appIcon: NSImage?
  var metrics: ProcessMetrics
  var launchDuration: TimeInterval?
  var timeToInteractiveDuration: TimeInterval?
  /// Metrics to render, in display order.
  var visibleMetrics: [HUDMetric]
  var thresholds: [HUDMetric: MetricThresholds]
  var isDetached: Bool
  var followsActiveWindow: Bool
  var missingAccessibility: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.appName == rhs.appName
      && lhs.metrics == rhs.metrics
      && lhs.launchDuration == rhs.launchDuration
      && lhs.timeToInteractiveDuration == rhs.timeToInteractiveDuration
      && lhs.visibleMetrics == rhs.visibleMetrics
      && lhs.thresholds == rhs.thresholds
      && lhs.isDetached == rhs.isDetached
      && lhs.followsActiveWindow == rhs.followsActiveWindow
      && lhs.missingAccessibility == rhs.missingAccessibility
  }
}

@MainActor
final class HUDWindow: NSPanel {
  static let cornerRadius: CGFloat = 22
  static let hostPadding: CGFloat = 10

  var onHideRequested: (() -> Void)?
  var onMetricToggleRequested: ((HUDMetric) -> Void)?
  /// The visible metrics, in the order the user just arranged them.
  var onMetricOrderChanged: (([HUDMetric]) -> Void)?
  var onDetachToggleRequested: (() -> Void)?
  var onAttachToActiveWindowRequested: (() -> Void)?
  /// The user asked to never show the HUD on the app it is currently showing.
  var onExcludeCurrentAppRequested: (() -> Void)?
  var onSettingsRequested: (() -> Void)?
  /// The user dropped the HUD near an anchor of the host window.
  var onSnapped: ((AppSettings.HUDPosition) -> Void)?
  /// The user dropped the detached HUD somewhere on screen.
  var onDetachedOriginChanged: ((CGPoint) -> Void)?

  /// True while the user drags the HUD or a re-attach animation is running. The controller must
  /// not reposition the window in that state.
  var isBeingManipulated: Bool { dragCandidate != nil || isAnimatingFrame }

  private let glassView = HUDWindow.makeGlassView()
  private let hudView = HUDContentView()
  private var lastPositionUpdateTime: TimeInterval?
  private var hostFrame: CGRect?
  private var isDetached = false
  private var dragCandidate: AppSettings.HUDPosition??
  private var isAnimatingFrame = false

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    setUpWindow()
    setUpContentView()
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func update(snapshot: HUDSnapshot) {
    isDetached = snapshot.isDetached
    hudView.update(snapshot: snapshot)
    updateContentSize()
  }

  /// Keeps the HUD anchored to `windowFrame`, easing toward the target while the host window moves.
  /// Returns true once the HUD sits exactly on its target; call again on a timer until it does.
  @discardableResult
  func follow(hostFrame windowFrame: CGRect, anchor: AppSettings.HUDPosition) -> Bool {
    hostFrame = windowFrame
    guard !isBeingManipulated else { return true }
    return moveToward(anchoredOrigin(in: windowFrame, anchor: anchor))
  }

  /// Places the detached HUD at `origin` (or keeps it where it is when `origin` is nil).
  func placeDetached(at origin: CGPoint?) {
    guard !isBeingManipulated else { return }
    lastPositionUpdateTime = nil
    let target = Self.clampedOrigin(origin ?? frame.origin, size: frame.size)
    guard target != frame.origin else { return }
    setFrameOrigin(target)
  }

  /// Animates the HUD onto `anchor` of the host window: after re-attaching, after a drag snaps,
  /// or after the position changes in Settings.
  func animateAttach(to windowFrame: CGRect, anchor: AppSettings.HUDPosition) {
    hostFrame = windowFrame
    lastPositionUpdateTime = nil
    let target = anchoredOrigin(in: windowFrame, anchor: anchor)
    guard target != frame.origin else { return }
    animateFrameOrigin(to: target, duration: 0.3)
  }
}

// MARK: - Dragging

extension HUDWindow {
  func beginDrag() {
    dragCandidate = .some(isDetached ? nil : nearestAnchor())
  }

  func dragMoved(by delta: CGPoint, from initialOrigin: CGPoint) {
    guard dragCandidate != nil else { return }
    setFrameOrigin(CGPoint(x: initialOrigin.x + delta.x, y: initialOrigin.y + delta.y))
    guard !isDetached, let candidate = nearestAnchor() else { return }
    if dragCandidate != .some(candidate) {
      dragCandidate = .some(candidate)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
  }

  func endDrag(moved: Bool) {
    guard let candidate = dragCandidate else { return }
    dragCandidate = nil
    guard moved else { return }

    if isDetached {
      let origin = Self.clampedOrigin(frame.origin, size: frame.size)
      setFrameOrigin(origin)
      onDetachedOriginChanged?(origin)
      return
    }

    // The controller stores the anchor and animates the HUD into place through `animateAttach`.
    if let anchor = candidate {
      onSnapped?(anchor)
    }
  }
}

// MARK: - Setup

private extension HUDWindow {
  func setUpWindow() {
    isFloatingPanel = true
    isOpaque = false
    hasShadow = true
    backgroundColor = .clear
    animationBehavior = .none
    level = .floating
    ignoresMouseEvents = false
    isMovable = false
    isMovableByWindowBackground = false
    tabbingMode = .disallowed
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
  }

  func setUpContentView() {
    let containerView = NSView()
    contentView = containerView

    glassView.translatesAutoresizingMaskIntoConstraints = false
    hudView.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(glassView)
    containerView.addSubview(hudView)

    NSLayoutConstraint.activate([
      glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      glassView.topAnchor.constraint(equalTo: containerView.topAnchor),
      glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
      hudView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      hudView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      hudView.topAnchor.constraint(equalTo: containerView.topAnchor),
      hudView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    hudView.onHideRequested = { [weak self] in self?.onHideRequested?() }
    hudView.onMetricToggleRequested = { [weak self] metric in self?.onMetricToggleRequested?(metric) }
    hudView.onMetricOrderChanged = { [weak self] order in self?.onMetricOrderChanged?(order) }
    hudView.onDetachToggleRequested = { [weak self] in self?.onDetachToggleRequested?() }
    hudView.onAttachToActiveWindowRequested = { [weak self] in self?.onAttachToActiveWindowRequested?() }
    hudView.onExcludeCurrentAppRequested = { [weak self] in self?.onExcludeCurrentAppRequested?() }
    hudView.onSettingsRequested = { [weak self] in self?.onSettingsRequested?() }

    updateContentSize()
  }
}

// MARK: - Private functionality

private extension HUDWindow {
  func anchoredOrigin(in windowFrame: CGRect, anchor: AppSettings.HUDPosition) -> CGPoint {
    let padding = Self.hostPadding
    let size = frame.size
    let x: CGFloat = switch anchor.column {
    case 0: windowFrame.minX + padding
    case 1: windowFrame.midX - (size.width / 2)
    default: windowFrame.maxX - size.width - padding
    }
    let y = anchor.isTop
      ? windowFrame.maxY - size.height - padding
      : windowFrame.minY + padding
    return Self.clampedOrigin(CGPoint(x: x, y: y), size: size, near: windowFrame)
  }

  /// The anchor whose slot is closest to the HUD’s current center.
  func nearestAnchor() -> AppSettings.HUDPosition? {
    guard let hostFrame else { return nil }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return AppSettings.HUDPosition.allCases.min { lhs, rhs in
      distance(from: center, to: anchoredOrigin(in: hostFrame, anchor: lhs))
        < distance(from: center, to: anchoredOrigin(in: hostFrame, anchor: rhs))
    }
  }

  func distance(from center: CGPoint, to origin: CGPoint) -> CGFloat {
    let anchorCenter = CGPoint(x: origin.x + (frame.width / 2), y: origin.y + (frame.height / 2))
    return hypot(center.x - anchorCenter.x, center.y - anchorCenter.y)
  }

  static func clampedOrigin(_ origin: CGPoint, size: CGSize, near windowFrame: CGRect? = nil) -> CGPoint {
    let probe = windowFrame ?? CGRect(origin: origin, size: size)
    let screen = NSScreen.screens.first { $0.frame.intersects(probe) } ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return origin }
    let padding = hostPadding
    return CGPoint(
      x: min(max(origin.x, visibleFrame.minX + padding), visibleFrame.maxX - size.width - padding),
      y: min(max(origin.y, visibleFrame.minY + padding), visibleFrame.maxY - size.height - padding)
    )
  }

  func animateFrameOrigin(to origin: CGPoint, duration: TimeInterval) {
    isAnimatingFrame = true
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().setFrame(CGRect(origin: origin, size: frame.size), display: true)
    }, completionHandler: { [weak self] in
      Task { @MainActor in
        self?.isAnimatingFrame = false
      }
    })
  }

  /// Eases toward `targetOrigin`; returns true when the HUD is there.
  func moveToward(_ targetOrigin: NSPoint) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    defer { lastPositionUpdateTime = now }

    guard isVisible, let lastPositionUpdateTime else {
      setFrameOrigin(targetOrigin)
      return true
    }

    let deltaX = targetOrigin.x - frame.origin.x
    let deltaY = targetOrigin.y - frame.origin.y
    let distance = hypot(deltaX, deltaY)
    guard distance > 0.5 else {
      if frame.origin != targetOrigin {
        setFrameOrigin(targetOrigin)
      }
      return true
    }
    guard distance < 400 else {
      setFrameOrigin(targetOrigin)
      return true
    }

    let elapsed = min(max(now - lastPositionUpdateTime, 0), 0.25)
    let response = 1 - exp(-elapsed / 0.08)
    setFrameOrigin(NSPoint(
      x: frame.origin.x + (deltaX * response),
      y: frame.origin.y + (deltaY * response)
    ))
    return false
  }

  func updateContentSize() {
    let size = hudView.intrinsicContentSize
    guard size.width > 1, size.height > 1 else { return }
    guard size != frame.size else { return }

    // Keep the HUD glued to its anchor edge while its size changes.
    var origin = frame.origin
    if let hostFrame, !isDetached {
      if frame.midX > hostFrame.midX { origin.x += frame.width - size.width }
      if frame.midY > hostFrame.midY { origin.y += frame.height - size.height }
    }
    setFrame(CGRect(origin: origin, size: size), display: true)
    invalidateShadow()
  }

  static func makeGlassView() -> NSView {
    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .regular
      glassView.cornerRadius = cornerRadius
      if #available(macOS 27.0, *) {
        // Interactive glass adds a second inset rim on macOS 27.
        glassView.effectIsInteractive = false
      }
      return glassView
    }

    let blurView = NSVisualEffectView()
    blurView.material = .hudWindow
    blurView.blendingMode = .behindWindow
    blurView.state = .active
    blurView.wantsLayer = true
    blurView.layer?.cornerRadius = cornerRadius
    blurView.layer?.masksToBounds = true
    return blurView
  }
}

@MainActor
private final class HUDContentView: NSView {
  private enum Drag {
    case window(initialMouse: CGPoint, initialOrigin: CGPoint, moved: Bool)
    case metric(view: MetricView, moved: Bool)
  }

  private static let horizontalInset: CGFloat = 14
  private static let verticalInset: CGFloat = 12

  private let appIconView = NSImageView()
  private let appNameLabel = NSTextField(labelWithString: "")
  private let detachButton = FirstMouseButton()
  private let headerStack = NSStackView()
  private let metricsStack = MetricsStackView()
  private let highlightView = MetricHighlightView()
  private let warningLabel = NSTextField(labelWithString: "")
  private let expandedStack = NSStackView()
  private let metricViews: [HUDMetric: MetricView] = Dictionary(
    uniqueKeysWithValues: HUDMetric.allCases.map { ($0, MetricView(label: $0.shortLabel, widthTemplate: $0.widthTemplate)) }
  )
  private var snapshot: HUDSnapshot?
  private var drag: Drag?
  private var hoveredMetricView: MetricView? {
    didSet { if hoveredMetricView !== oldValue { updateHighlight(animated: true) } }
  }
  private var detachButtonTitle = ""
  private var toolTipTimer: Timer?
  private var hoverTimer: Timer?
  private let toolTipWindow = HUDToolTipWindow()

  var onHideRequested: (() -> Void)?
  var onMetricToggleRequested: ((HUDMetric) -> Void)?
  var onMetricOrderChanged: (([HUDMetric]) -> Void)?
  var onDetachToggleRequested: (() -> Void)?
  var onAttachToActiveWindowRequested: (() -> Void)?
  var onExcludeCurrentAppRequested: (() -> Void)?
  var onSettingsRequested: (() -> Void)?

  override var intrinsicContentSize: NSSize {
    let fittingSize = expandedStack.fittingSize
    return NSSize(
      width: fittingSize.width + (Self.horizontalInset * 2),
      height: fittingSize.height + (Self.verticalInset * 2)
    )
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUpView()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  // The panel never becomes key, so AppKit only delivers enter/exit here, never mouseMoved.
  // Hover is polled while the pointer is inside.
  override func mouseEntered(with event: NSEvent) {
    hoverTimer?.invalidate()
    hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateHover() }
    }
    updateHover()
  }

  override func mouseExited(with event: NSEvent) {
    hoverTimer?.invalidate()
    hoverTimer = nil
    updateToolTip(isOverDetachButton: false)
    guard drag == nil else { return }
    hoveredMetricView = nil
    NSCursor.arrow.set()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Everything except the detach button is handled here so drags work from any pixel.
    let hit = super.hitTest(point)
    if hit === detachButton { return hit }
    return bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let snapshot else { return nil }
    let menu = NSMenu()

    let detachItem = NSMenuItem(
      title: snapshot.isDetached ? "Attach to Window" : "Detach from Window",
      action: #selector(toggleDetached),
      keyEquivalent: ""
    )
    detachItem.target = self
    menu.addItem(detachItem)

    if !snapshot.followsActiveWindow {
      let attachItem = NSMenuItem(title: "Attach to Active Window", action: #selector(attachToActiveWindow), keyEquivalent: "")
      attachItem.target = self
      menu.addItem(attachItem)
    }

    let hideItem = NSMenuItem(title: "Hide HUD", action: #selector(hideHUD), keyEquivalent: "")
    hideItem.target = self
    menu.addItem(hideItem)

    let excludeItem = NSMenuItem(title: "Never Show on \(snapshot.appName)", action: #selector(excludeCurrentApp), keyEquivalent: "")
    excludeItem.target = self
    menu.addItem(excludeItem)
    menu.addItem(.separator())

    for (index, metric) in HUDMetric.allCases.enumerated() {
      let item = NSMenuItem(title: metric.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      item.state = snapshot.visibleMetrics.contains(metric) ? .on : .off
      menu.addItem(item)
    }

    menu.addItem(.separator())
    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
    settingsItem.target = self
    menu.addItem(settingsItem)
    return menu
  }

  override func mouseDown(with event: NSEvent) {
    updateToolTip(isOverDetachButton: false)
    let point = convert(event.locationInWindow, from: nil)
    if let metricView = reorderableMetricView(at: point) {
      drag = .metric(view: metricView, moved: false)
      hoveredMetricView = metricView
      NSCursor.closedHand.set()
    } else {
      drag = .window(initialMouse: NSEvent.mouseLocation, initialOrigin: window?.frame.origin ?? .zero, moved: false)
      hudWindow?.beginDrag()
    }
  }

  override func mouseDragged(with event: NSEvent) {
    switch drag {
    case let .window(initialMouse, initialOrigin, moved):
      let mouse = NSEvent.mouseLocation
      let delta = CGPoint(x: mouse.x - initialMouse.x, y: mouse.y - initialMouse.y)
      guard moved || hypot(delta.x, delta.y) >= 3 else { return }
      drag = .window(initialMouse: initialMouse, initialOrigin: initialOrigin, moved: true)
      hudWindow?.dragMoved(by: delta, from: initialOrigin)

    case let .metric(view, moved):
      if !moved {
        drag = .metric(view: view, moved: true)
      }
      reorder(view, toward: metricsStack.convert(event.locationInWindow, from: nil).x)

    case nil:
      break
    }
  }

  override func mouseUp(with event: NSEvent) {
    switch drag {
    case let .window(_, _, moved):
      hudWindow?.endDrag(moved: moved)

    case let .metric(_, moved):
      if moved {
        let visibleOrder = metricsStack.arrangedSubviews.compactMap { view in
          metricViews.first { $0.value === view }?.key
        }
        onMetricOrderChanged?(visibleOrder)
      }

    case nil:
      break
    }
    drag = nil
    hoveredMetricView = reorderableMetricView(at: convert(event.locationInWindow, from: nil))
    (hoveredMetricView == nil ? NSCursor.arrow : NSCursor.openHand).set()
  }

  func update(snapshot: HUDSnapshot) {
    self.snapshot = snapshot
    appNameLabel.stringValue = snapshot.appName
    appIconView.image = snapshot.appIcon
    appIconView.isHidden = snapshot.appIcon == nil

    let metrics = snapshot.metrics
    let memoryMegabytes = metrics.memoryBytes.map { Double($0) / 1_048_576 }
    set(.cpu, value: metrics.cpuText, color: color(for: metrics.cpuPercent, thresholds: snapshot.thresholds[.cpu]))
    set(.memory, value: metrics.memoryText, color: color(for: memoryMegabytes, thresholds: snapshot.thresholds[.memory]))
    set(
      .energyImpact,
      value: metrics.energyImpactText,
      color: color(for: metrics.energyImpact, thresholds: snapshot.thresholds[.energyImpact])
    )
    set(
      .twelveHourPower,
      value: metrics.twelveHourText,
      color: color(for: metrics.twelveHourEnergyImpact, thresholds: snapshot.thresholds[.twelveHourPower])
    )
    set(
      .launchTimer,
      value: durationText(snapshot.launchDuration),
      color: color(for: snapshot.launchDuration, thresholds: snapshot.thresholds[.launchTimer])
    )
    set(
      .timeToInteractive,
      value: durationText(snapshot.timeToInteractiveDuration),
      color: color(for: snapshot.timeToInteractiveDuration, thresholds: snapshot.thresholds[.timeToInteractive])
    )

    if case .metric = drag {
      // Don't fight the user's reordering; the new order is applied on mouse up.
    } else {
      updateArrangedMetrics(snapshot.visibleMetrics)
    }
    updateDetachButton(isDetached: snapshot.isDetached)
    updateWarning(snapshot: snapshot)
    invalidateIntrinsicContentSize()
  }
}

// MARK: - Setup

private extension HUDContentView {
  func setUpView() {
    // `activeAlways`: the panel never becomes key, so hover has to work without activation.
    // `inVisibleRect` keeps the area in sync with the bounds without `updateTrackingAreas`.
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    ))

    appIconView.imageScaling = .scaleProportionallyDown
    appIconView.wantsLayer = true
    appIconView.layer?.cornerRadius = 3
    appIconView.layer?.masksToBounds = true
    appIconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      appIconView.widthAnchor.constraint(equalToConstant: 16),
      appIconView.heightAnchor.constraint(equalToConstant: 16),
    ])

    appNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    appNameLabel.textColor = .labelColor
    appNameLabel.lineBreakMode = .byTruncatingTail
    appNameLabel.maximumNumberOfLines = 1
    appNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    appNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true

    detachButton.isBordered = false
    detachButton.bezelStyle = .accessoryBarAction
    detachButton.imagePosition = .imageOnly
    detachButton.imageScaling = .scaleProportionallyDown
    detachButton.contentTintColor = .secondaryLabelColor
    detachButton.target = self
    detachButton.action = #selector(toggleDetached)
    detachButton.setButtonType(.momentaryChange)
    detachButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      detachButton.widthAnchor.constraint(equalToConstant: 16),
      detachButton.heightAnchor.constraint(equalToConstant: 16),
    ])
    updateDetachButton(isDetached: false)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)

    headerStack.orientation = .horizontal
    headerStack.alignment = .centerY
    headerStack.spacing = 8
    headerStack.addArrangedSubview(appIconView)
    headerStack.addArrangedSubview(appNameLabel)
    headerStack.addArrangedSubview(spacer)
    headerStack.addArrangedSubview(detachButton)
    headerStack.setCustomSpacing(4, after: appNameLabel)

    metricsStack.orientation = .horizontal
    metricsStack.alignment = .top
    metricsStack.spacing = 12
    metricsStack.addSubview(highlightView, positioned: .below, relativeTo: nil)
    highlightView.alphaValue = 0
    metricsStack.onLayout = { [weak self] in
      self?.updateHighlight(animated: false)
    }

    warningLabel.font = .systemFont(ofSize: 9, weight: .medium)
    warningLabel.textColor = .systemYellow

    expandedStack.orientation = .vertical
    expandedStack.alignment = .leading
    expandedStack.spacing = 8
    expandedStack.translatesAutoresizingMaskIntoConstraints = false
    expandedStack.addArrangedSubview(headerStack)
    expandedStack.addArrangedSubview(metricsStack)
    expandedStack.addArrangedSubview(warningLabel)

    addSubview(expandedStack)

    NSLayoutConstraint.activate([
      expandedStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
      expandedStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
      expandedStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
      expandedStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
      headerStack.widthAnchor.constraint(equalTo: metricsStack.widthAnchor),
      headerStack.widthAnchor.constraint(greaterThanOrEqualTo: warningLabel.widthAnchor),
      headerStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
  }
}

// MARK: - Private functionality

private extension HUDContentView {
  var hudWindow: HUDWindow? { window as? HUDWindow }

  @objc func hideHUD() {
    onHideRequested?()
  }

  @objc func toggleDetached() {
    onDetachToggleRequested?()
  }

  @objc func attachToActiveWindow() {
    onAttachToActiveWindowRequested?()
  }

  @objc func excludeCurrentApp() {
    onExcludeCurrentAppRequested?()
  }

  @objc func showSettings() {
    onSettingsRequested?()
  }

  @objc func toggleMetric(_ sender: NSMenuItem) {
    guard HUDMetric.allCases.indices.contains(sender.tag) else { return }
    onMetricToggleRequested?(HUDMetric.allCases[sender.tag])
  }

  func metricView(at point: NSPoint) -> MetricView? {
    let stackPoint = metricsStack.convert(point, from: self)
    return metricsStack.arrangedSubviews.first { $0.frame.contains(stackPoint) } as? MetricView
  }

  func updateHover() {
    guard drag == nil, let window else { return }
    let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    guard bounds.contains(point) else {
      hoveredMetricView = nil
      updateToolTip(isOverDetachButton: false)
      return
    }
    hoveredMetricView = reorderableMetricView(at: point)
    (hoveredMetricView == nil ? NSCursor.arrow : NSCursor.openHand).set()
    updateToolTip(isOverDetachButton: detachButton.bounds.contains(detachButton.convert(point, from: self)))
  }

  /// A metric under `point` that can be dragged: reordering needs at least two visible metrics.
  func reorderableMetricView(at point: NSPoint) -> MetricView? {
    guard (snapshot?.visibleMetrics.count ?? 0) > 1 else { return nil }
    return metricView(at: point)
  }

  /// Moves the hover background under the hovered (or dragged) metric, or fades it out.
  func updateHighlight(animated: Bool) {
    let target: MetricView? = if case let .metric(view, _) = drag { view } else { hoveredMetricView }
    guard let target, target.superview === metricsStack else {
      if animated {
        highlightView.animator().alphaValue = 0
      } else {
        highlightView.alphaValue = 0
      }
      return
    }

    let frame = target.frame.insetBy(dx: -6, dy: -4)
    if animated, highlightView.alphaValue > 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        highlightView.animator().frame = frame
        highlightView.animator().alphaValue = 1
      }
    } else {
      highlightView.frame = frame
      if animated {
        highlightView.animator().alphaValue = 1
      } else {
        highlightView.alphaValue = 1
      }
    }
  }

  func reorder(_ view: MetricView, toward x: CGFloat) {
    let arranged = metricsStack.arrangedSubviews
    guard let currentIndex = arranged.firstIndex(of: view) else { return }
    let others = arranged.filter { $0 !== view }
    let targetIndex = others.firstIndex { x < $0.frame.midX } ?? others.count
    guard targetIndex != currentIndex else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.allowsImplicitAnimation = true
      metricsStack.removeArrangedSubview(view)
      metricsStack.insertArrangedSubview(view, at: targetIndex)
      metricsStack.layoutSubtreeIfNeeded()
      highlightView.frame = view.frame.insetBy(dx: -6, dy: -4)
    }
  }

  func set(_ metric: HUDMetric, value: String, color: NSColor) {
    metricViews[metric]?.value = value
    metricViews[metric]?.valueColor = color
  }

  func updateDetachButton(isDetached: Bool) {
    // Picture-in-picture glyphs: a small panel leaving the window (detach) or returning to it (attach).
    // The arrow direction alone is too subtle at this size, so the detached state is also tinted.
    let symbolName = isDetached ? "pip.enter" : "pip.exit"
    let description = isDetached ? "Attach to Window" : "Detach from Window"
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
    detachButton.image = image?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    detachButton.contentTintColor = isDetached ? .controlAccentColor : .secondaryLabelColor
    // The system tool tip never shows on a panel that cannot become key; `HUDToolTipWindow` does.
    // This runs on every snapshot change, so it must not disturb a pending hover delay.
    detachButtonTitle = description
    if toolTipWindow.isVisible {
      showToolTip()
    }
  }

  /// Shows the detach button’s tool tip after the usual delay, or hides it.
  func updateToolTip(isOverDetachButton: Bool) {
    guard isOverDetachButton else {
      toolTipTimer?.invalidate()
      toolTipTimer = nil
      toolTipWindow.hide()
      return
    }
    guard toolTipTimer == nil, !toolTipWindow.isVisible else { return }
    toolTipTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.showToolTip() }
    }
  }

  func showToolTip() {
    toolTipTimer = nil
    guard let window else { return }
    let buttonRect = window.convertToScreen(detachButton.convert(detachButton.bounds, to: nil))
    toolTipWindow.show(detachButtonTitle, below: buttonRect)
  }

  func updateWarning(snapshot: HUDSnapshot) {
    warningLabel.stringValue = "Enable \(AccessibilityPermission.displayName) to attach to windows"
    warningLabel.isHidden = !snapshot.missingAccessibility
  }

  func updateArrangedMetrics(_ metrics: [HUDMetric]) {
    let views = metrics.compactMap { metricViews[$0] }
    guard views != metricsStack.arrangedSubviews else { return }
    metricsStack.arrangedSubviews.forEach { view in
      metricsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    views.forEach(metricsStack.addArrangedSubview)
  }

  /// Unavailable values are dimmed; everything else is the label color unless a threshold is crossed.
  func color(for value: Double?, thresholds: MetricThresholds?) -> NSColor {
    guard let value else { return .secondaryLabelColor }
    if let red = thresholds?.red, value >= red { return .metricRed }
    if let orange = thresholds?.orange, value >= orange { return .metricOrange }
    return .labelColor
  }

  func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "—" }
    if duration < 1 {
      let milliseconds = min(Int((duration * 1_000).rounded()), 999)
      return "\(milliseconds)ms"
    }
    if duration < 10 {
      return String(format: "%.2fs", duration)
    }
    if duration < 60 {
      return String(format: "%.1fs", duration)
    }
    let totalSeconds = Int(duration.rounded())
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
  }
}

/// Receives clicks even though the HUD panel never becomes key.
@MainActor
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

/// A tool tip that works for non-key panels, styled like the system one.
@MainActor
private final class HUDToolTipWindow: NSPanel {
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    animationBehavior = .none
    level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

    let background = NSVisualEffectView()
    background.material = .toolTip
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 4
    background.layer?.masksToBounds = true
    contentView = background

    label.font = .toolTipsFont(ofSize: 11)
    label.textColor = .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
      label.topAnchor.constraint(equalTo: background.topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -3),
    ])
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Centers the tip under `anchor` (screen coordinates), flipping above it near the bottom edge.
  func show(_ text: String, below anchor: NSRect) {
    label.stringValue = text
    let size = contentView?.fittingSize ?? .zero
    var origin = NSPoint(x: anchor.midX - (size.width / 2), y: anchor.minY - 6 - size.height)
    if let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
      if origin.y < visible.minY {
        origin.y = anchor.maxY + 6
      }
      origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
    }
    setFrame(NSRect(origin: origin, size: size), display: true)
    orderFrontRegardless()
  }

  func hide() {
    guard isVisible else { return }
    orderOut(nil)
  }
}

/// Reports layout passes so the hover highlight can track the arranged metric frames.
@MainActor
private final class MetricsStackView: NSStackView {
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// Rounded fill shown behind a metric that can be dragged.
@MainActor
private final class MetricHighlightView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 6
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
  }
}

@MainActor
private final class MetricView: NSStackView {
  private let valueLabel = NSTextField(labelWithString: "")

  var value: String {
    get { valueLabel.stringValue }
    set { valueLabel.stringValue = newValue }
  }

  var valueColor: NSColor? {
    get { valueLabel.textColor }
    set { valueLabel.textColor = newValue }
  }

  /// `widthTemplate` is the widest expected value; the cell never shrinks below its width.
  init(label: String, widthTemplate: String) {
    super.init(frame: .zero)

    let nameLabel = NSTextField(labelWithString: label)
    nameLabel.attributedStringValue = NSAttributedString(
      string: label,
      attributes: [
        .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.6,
      ]
    )

    let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    valueLabel.font = valueFont
    valueLabel.textColor = .labelColor
    let templateWidth = (widthTemplate as NSString).size(withAttributes: [.font: valueFont]).width
    valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: templateWidth.rounded(.up)).isActive = true

    orientation = .vertical
    alignment = .leading
    spacing = 1
    addArrangedSubview(nameLabel)
    addArrangedSubview(valueLabel)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

private extension NSColor {
  static let metricRed = NSColor(name: "metricRed") { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
      return NSColor(calibratedRed: 1.00, green: 0.36, blue: 0.34, alpha: 1)
    }
    return NSColor(calibratedRed: 0.74, green: 0.05, blue: 0.08, alpha: 1)
  }

  static let metricOrange = NSColor(name: "metricOrange") { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
      return NSColor(calibratedRed: 1.00, green: 0.64, blue: 0.18, alpha: 1)
    }
    return NSColor(calibratedRed: 0.68, green: 0.29, blue: 0.00, alpha: 1)
  }

}
