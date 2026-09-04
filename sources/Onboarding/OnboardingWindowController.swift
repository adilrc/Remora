internal import AppKit

/// Walks the user through granting the Accessibility permission. Clicking “Grant” opens System
/// Settings, slides this window next to it, and turns the app icon into a drag source so the app
/// can be dropped straight into the permission list. A checkbox also offers Visually Complete;
/// ticking it turns the metric on and runs the same drag flow for Screen Recording, which macOS
/// only applies after a relaunch. The system's own Screen Recording alert is never requested: it
/// tends to open behind other windows.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  /// Set before relaunching for Screen Recording so the next launch reopens this window.
  static let resumeAfterRelaunchKey = "onboarding.resumeAfterRelaunch"

  private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

  private var window: NSWindow?
  private var onboardingView: OnboardingView?
  private var permissionTimer: Timer?
  private var screenRecordingTimer: Timer?
  private var settingsWindowTimer: Timer?
  private var settingsWindowSearchStartedAt: Date?

  /// Called with `true` when the window comes on screen and `false` when it closes.
  var onVisibilityChanged: ((Bool) -> Void)?

  var isShowing: Bool { window?.isVisible ?? false }

  func show() {
    if window == nil {
      window = makeWindow()
    }
    guard let window, let onboardingView else { return }

    onboardingView.isVisuallyCompleteEnabled = AppSettings.shared.showsVisuallyComplete
    refreshVisuallyCompleteCaption()
    if !window.isVisible {
      window.level = .normal
      window.center()
      onboardingView.stage = baseStage
    }
    AppActivation.windowWillShow(window)
    window.makeKeyAndOrderFront(nil)
    startPermissionPolling()
    onVisibilityChanged?(true)

    // Opened with the metric on but the permission missing, typically from Settings: go straight
    // to the drag so the user is not left guessing what to do.
    if !AccessibilityPermission.isGranted {
      return
    }
    if AppSettings.shared.showsVisuallyComplete, !ScreenRecordingPermission.isGranted {
      beginScreenRecordingDrag()
    }
  }

  func windowWillClose(_ notification: Notification) {
    stopTimers()
    if let window {
      AppActivation.windowWillClose(window)
    }
    onVisibilityChanged?(false)
  }
}

// MARK: - Private functionality

private extension OnboardingWindowController {
  func makeWindow() -> NSWindow {
    let view = OnboardingView()
    view.onGrant = { [weak self] in self?.grant() }
    view.onOpenScreenRecordingSettings = { [weak self] in self?.beginScreenRecordingDrag() }
    view.onCancelScreenRecording = { [weak self] in self?.cancelScreenRecordingDrag() }
    view.onDone = { [weak self] in self?.window?.close() }
    view.onVisuallyCompleteChanged = { [weak self] isEnabled in
      self?.setVisuallyCompleteEnabled(isEnabled)
    }
    view.onRelaunch = { [weak self] in self?.relaunch() }
    onboardingView = view

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: OnboardingView.size),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Welcome"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.contentView = view
    window.delegate = self
    return window
  }

  func grant() {
    AccessibilityPermission.openSystemSettings()
    onboardingView?.stage = .dragging
    slideNextToSystemSettings()
  }

  /// The stage to rest on when no drag is in progress.
  var baseStage: OnboardingView.Stage {
    AccessibilityPermission.isGranted ? .granted(playSound: false) : .intro
  }

  func setVisuallyCompleteEnabled(_ isEnabled: Bool) {
    AppSettings.shared.showsVisuallyComplete = isEnabled
    refreshVisuallyCompleteCaption()
    guard isEnabled, !ScreenRecordingPermission.isGranted else { return }
    beginScreenRecordingDrag()
  }

  /// Same routine as for Accessibility: open the pane, sit next to it, offer the icon to drag.
  func beginScreenRecordingDrag() {
    ScreenRecordingPermission.openSystemSettings()
    onboardingView?.stage = .draggingScreenRecording
    slideNextToSystemSettings()
  }

  /// Leaves the metric on; the caption keeps explaining what is missing and polling continues.
  func cancelScreenRecordingDrag() {
    onboardingView?.stage = baseStage
  }

  /// Matches the caption to the setting and the permission, and polls while a grant is awaited.
  func refreshVisuallyCompleteCaption() {
    guard AppSettings.shared.showsVisuallyComplete else {
      stopScreenRecordingPolling()
      onboardingView?.setVisuallyCompleteCaption(.initial)
      return
    }
    if ScreenRecordingPermission.isGranted {
      stopScreenRecordingPolling()
      onboardingView?.setVisuallyCompleteCaption(.granted)
    } else {
      onboardingView?.setVisuallyCompleteCaption(.waiting)
      startScreenRecordingPolling()
    }
  }

  /// Screen Recording only takes effect in a fresh process. A shell waits for this one to exit,
  /// then reopens the bundle; the defaults flag brings this window straight back.
  func relaunch() {
    UserDefaults.standard.set(true, forKey: Self.resumeAfterRelaunchKey)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
      Bundle.main.bundlePath,
    ]
    do {
      try process.run()
    } catch {
      UserDefaults.standard.removeObject(forKey: Self.resumeAfterRelaunchKey)
      return
    }
    NSApp.terminate(nil)
  }

  func slideNextToSystemSettings() {
    guard let window else { return }
    window.level = .floating
    settingsWindowSearchStartedAt = Date()
    settingsWindowTimer?.invalidate()
    settingsWindowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.lookForSystemSettingsWindow() }
    }
  }

  func lookForSystemSettingsWindow() {
    guard let startedAt = settingsWindowSearchStartedAt, Date().timeIntervalSince(startedAt) < 6 else {
      settingsWindowTimer?.invalidate()
      settingsWindowTimer = nil
      reactivate()
      return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsBundleIdentifier).first,
          let quartzFrame = CGWindowList.primaryWindowFrame(pid: app.processIdentifier)
    else { return }

    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
    moveWindow(nextTo: ScreenGeometry.cocoaRect(fromQuartz: quartzFrame))
    reactivate()
  }

  /// Opening System Settings hands it focus; take it back so the icon is ready to drag.
  func reactivate() {
    guard let window, window.isVisible else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func moveWindow(nextTo settingsFrame: CGRect) {
    guard let window else { return }
    let size = window.frame.size
    let gap: CGFloat = 16
    let screen = NSScreen.screens.first { $0.frame.intersects(settingsFrame) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? settingsFrame

    // Beside System Settings, top edges aligned: to the right when it fits, else to the left,
    // else whichever side has more room.
    let spaceRight = visible.maxX - settingsFrame.maxX
    let spaceLeft = settingsFrame.minX - visible.minX
    let needed = size.width + gap
    let onRight = spaceRight >= needed || (spaceLeft < needed && spaceRight >= spaceLeft)
    var origin = CGPoint(
      x: onRight ? settingsFrame.maxX + gap : settingsFrame.minX - gap - size.width,
      y: settingsFrame.maxY - size.height
    )
    origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.45
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(CGRect(origin: origin, size: size), display: true)
    }
  }

  func startPermissionPolling() {
    guard permissionTimer == nil, !AccessibilityPermission.isGranted else { return }
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkPermission() }
    }
  }

  func checkPermission() {
    guard AccessibilityPermission.isGranted else { return }
    permissionTimer?.invalidate()
    permissionTimer = nil
    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
    onboardingView?.stage = .granted(playSound: true)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func startScreenRecordingPolling() {
    guard screenRecordingTimer == nil else { return }
    screenRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkScreenRecordingPermission() }
    }
  }

  func checkScreenRecordingPermission() {
    guard ScreenRecordingPermission.isGranted else { return }
    stopScreenRecordingPolling()
    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
    if onboardingView?.stage == .draggingScreenRecording {
      onboardingView?.stage = baseStage
    }
    onboardingView?.setVisuallyCompleteCaption(.grantedPendingRelaunch)
    NSSound(named: "Glass")?.play()
    reactivate()
  }

  func stopScreenRecordingPolling() {
    screenRecordingTimer?.invalidate()
    screenRecordingTimer = nil
  }

  func stopTimers() {
    permissionTimer?.invalidate()
    permissionTimer = nil
    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
    stopScreenRecordingPolling()
  }
}

@MainActor
private final class OnboardingView: NSView {
  enum Stage: Equatable {
    case intro
    case dragging
    case draggingScreenRecording
    case granted(playSound: Bool)
  }

  enum VisuallyCompleteCaption {
    case initial
    case waiting
    case grantedPendingRelaunch
    case granted
  }

  static let size = NSSize(width: 380, height: 470)
  static let largeIconSize: CGFloat = 140

  var onGrant: (() -> Void)?
  var onOpenScreenRecordingSettings: (() -> Void)?
  var onCancelScreenRecording: (() -> Void)?
  var onDone: (() -> Void)?
  var onVisuallyCompleteChanged: ((Bool) -> Void)?
  var onRelaunch: (() -> Void)?

  var isVisuallyCompleteEnabled: Bool {
    get { visuallyCompleteCheckbox.state == .on }
    set { visuallyCompleteCheckbox.state = newValue ? .on : .off }
  }

  func setVisuallyCompleteCaption(_ caption: VisuallyCompleteCaption) {
    let appName = AppInfo.name
    switch caption {
    case .initial:
      visuallyCompleteCaption.stringValue = "Watches the window render after launch. "
        + "Needs Screen Recording."
      visuallyCompleteCaption.textColor = .secondaryLabelColor
      setRelaunchButtonVisible(false)
    case .waiting:
      visuallyCompleteCaption.stringValue = "Drop \(appName) onto the Screen Recording list, "
        + "then relaunch it."
      visuallyCompleteCaption.textColor = .secondaryLabelColor
      setRelaunchButtonVisible(true)
    case .grantedPendingRelaunch:
      visuallyCompleteCaption.stringValue = "Screen Recording is granted. "
        + "Relaunch \(appName) to start measuring."
      visuallyCompleteCaption.textColor = .systemGreen
      setRelaunchButtonVisible(true)
    case .granted:
      visuallyCompleteCaption.stringValue = "Screen Recording is granted."
      visuallyCompleteCaption.textColor = .systemGreen
      setRelaunchButtonVisible(false)
    }
  }

  var stage: Stage = .intro {
    didSet { apply(stage, animated: true) }
  }

  private let iconContainer = NSView()
  private let iconView = DraggableAppIconView()
  private let checkmarkView = CheckmarkView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")
  private let visuallyCompleteCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let visuallyCompleteCaption = NSTextField(wrappingLabelWithString: "")
  private let relaunchButton = NSButton(title: "", target: nil, action: nil)
  private let visuallyCompleteStack = NSStackView()
  private let primaryButton = NSButton(title: "", target: nil, action: nil)
  private let secondaryButton = NSButton(title: "", target: nil, action: nil)
  private var iconSizeConstraint: NSLayoutConstraint?
  private var checkmarkSizeConstraint: NSLayoutConstraint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUpView()
    apply(.intro, animated: false)
  }

  required init?(coder: NSCoder) {
    return nil
  }

}

// MARK: - Setup

private extension OnboardingView {
  func setUpView() {
    wantsLayer = true

    // The icon lives in a fixed-size container so resizing it never moves anything else.
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    // Resolved through Launch Services like Finder does: `NSApp.applicationIconImage` can come back
    // as the generic placeholder for a bundle the system has not registered yet. That image reports
    // a 32-point size, which would leave the enlarged icon and the drag image rasterized small and
    // scaled up; asking for 512 points selects the large representation.
    let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    icon.size = NSSize(width: 512, height: 512)
    iconView.image = icon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(iconView)
    let iconSize = iconView.widthAnchor.constraint(equalToConstant: 96)
    iconSizeConstraint = iconSize
    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: Self.largeIconSize),
      iconContainer.heightAnchor.constraint(equalToConstant: Self.largeIconSize),
      iconSize,
      iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
    ])

    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.alignment = .center
    titleLabel.maximumNumberOfLines = 2
    titleLabel.preferredMaxLayoutWidth = 320
    titleLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true

    bodyLabel.font = .systemFont(ofSize: 13)
    bodyLabel.textColor = .secondaryLabelColor
    bodyLabel.alignment = .center
    bodyLabel.preferredMaxLayoutWidth = 300
    bodyLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true

    visuallyCompleteCheckbox.title = "Also measure Visually Complete"
    visuallyCompleteCheckbox.target = self
    visuallyCompleteCheckbox.action = #selector(visuallyCompleteAction)

    visuallyCompleteCaption.font = .systemFont(ofSize: 11)
    visuallyCompleteCaption.textColor = .secondaryLabelColor
    visuallyCompleteCaption.preferredMaxLayoutWidth = 282

    relaunchButton.title = "Relaunch \(AppInfo.name)"
    relaunchButton.bezelStyle = .rounded
    relaunchButton.controlSize = .small
    relaunchButton.target = self
    relaunchButton.action = #selector(relaunchAction)

    visuallyCompleteStack.setViews([visuallyCompleteCheckbox, visuallyCompleteCaption, relaunchButton], in: .top)
    visuallyCompleteStack.orientation = .vertical
    visuallyCompleteStack.alignment = .leading
    visuallyCompleteStack.spacing = 2
    visuallyCompleteStack.setCustomSpacing(6, after: visuallyCompleteCaption)
    visuallyCompleteStack.widthAnchor.constraint(equalToConstant: 300).isActive = true
    NSLayoutConstraint.activate([
      visuallyCompleteCaption.leadingAnchor.constraint(equalTo: visuallyCompleteStack.leadingAnchor, constant: 18),
      relaunchButton.leadingAnchor.constraint(equalTo: visuallyCompleteStack.leadingAnchor, constant: 18),
    ])
    setVisuallyCompleteCaption(.initial)

    primaryButton.bezelStyle = .rounded
    primaryButton.controlSize = .large
    primaryButton.keyEquivalent = "\r"
    primaryButton.target = self
    primaryButton.action = #selector(primaryAction)

    secondaryButton.bezelStyle = .rounded
    secondaryButton.isBordered = false
    secondaryButton.target = self
    secondaryButton.action = #selector(secondaryAction)
    secondaryButton.contentTintColor = .secondaryLabelColor

    let stack = NSStackView(views: [
      iconContainer, titleLabel, bodyLabel, visuallyCompleteStack, primaryButton, secondaryButton,
    ])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.setCustomSpacing(8, after: iconContainer)
    stack.setCustomSpacing(20, after: bodyLabel)
    stack.setCustomSpacing(24, after: visuallyCompleteStack)
    stack.setCustomSpacing(8, after: primaryButton)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    // The window keeps one size. The tall intro and granted layouts sit at the top margin; the
    // shorter drag stages, which leave out the Visually Complete block, centre instead of leaving
    // a hole between the text and the buttons.
    let centered = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
    centered.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 40),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
      centered,
    ])

    checkmarkView.alphaValue = 0
    checkmarkView.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(checkmarkView)
    let checkmarkSize = checkmarkView.widthAnchor.constraint(equalToConstant: 0)
    checkmarkSizeConstraint = checkmarkSize
    NSLayoutConstraint.activate([
      checkmarkSize,
      checkmarkView.heightAnchor.constraint(equalTo: checkmarkView.widthAnchor),
      checkmarkView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
      checkmarkView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
    ])
  }
}

// MARK: - Private functionality

private extension OnboardingView {
  @objc func primaryAction() {
    switch stage {
    case .intro, .dragging: onGrant?()
    case .draggingScreenRecording: onOpenScreenRecordingSettings?()
    case .granted: onDone?()
    }
  }

  @objc func secondaryAction() {
    switch stage {
    case .intro, .dragging: onDone?()
    case .draggingScreenRecording: onCancelScreenRecording?()
    case .granted: break
    }
  }

  @objc func visuallyCompleteAction() {
    onVisuallyCompleteChanged?(isVisuallyCompleteEnabled)
  }

  @objc func relaunchAction() {
    onRelaunch?()
  }

  func apply(_ stage: Stage, animated: Bool) {
    let permission = AccessibilityPermission.displayName
    let appName = AppInfo.name

    // Text and buttons change instantly; the layout pass below commits them before any animation.
    switch stage {
    case .intro:
      titleLabel.stringValue = "Welcome to \(appName)"
      bodyLabel.stringValue = "\(appName) needs the \(permission) permission to find the frontmost window "
        + "and pin the performance HUD to it."
      primaryButton.title = AccessibilityPermission.grantActionTitle
      secondaryButton.title = "Not Now"
      setSecondaryButtonVisible(true)

    case .dragging:
      titleLabel.stringValue = "Drag the icon into System Settings"
      bodyLabel.stringValue = "Drop the \(appName) icon onto the \(permission) list."
      primaryButton.title = "Open System Settings Again"
      secondaryButton.title = "Not Now"
      setSecondaryButtonVisible(true)

    case .draggingScreenRecording:
      titleLabel.stringValue = "Drag the icon into System Settings"
      bodyLabel.stringValue = "Drop the \(appName) icon onto the Screen Recording list. "
        + "Visually Complete starts measuring after a relaunch."
      primaryButton.title = "Open System Settings Again"
      secondaryButton.title = "Not Now"
      setSecondaryButtonVisible(true)

    case .granted:
      titleLabel.stringValue = "You’re all set"
      bodyLabel.stringValue = "The \(permission) permission is granted. The HUD will attach to the frontmost window."
      primaryButton.title = "Done"
      setSecondaryButtonVisible(false)
    }
    layoutSubtreeIfNeeded()

    // Showing or hiding the Visually Complete block re-centres everything. That shift animates with
    // the icon resize, except on completion, where the checkmark is the only thing that moves.
    let isGranted = if case .granted = stage { true } else { false }
    let showsVisuallyComplete = stage == .intro || isGranted
    if animated, !isGranted {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        setVisuallyCompleteVisible(showsVisuallyComplete)
        layoutSubtreeIfNeeded()
      }
    } else {
      setVisuallyCompleteVisible(showsVisuallyComplete)
      layoutSubtreeIfNeeded()
    }

    switch stage {
    case .intro:
      iconView.alphaValue = 1
      setIconSize(96, animated: animated)
      setCheckmarkVisible(false)

    case .dragging, .draggingScreenRecording:
      iconView.alphaValue = 1
      setIconSize(Self.largeIconSize, animated: animated)
      setCheckmarkVisible(false)

    case let .granted(playSound):
      setIconSize(96, animated: animated)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = animated ? 0.3 : 0
        iconView.animator().alphaValue = 0.12
      }
      if playSound {
        NSSound(named: "Glass")?.play()
      }
      setCheckmarkVisible(true, animated: animated)
    }
  }

  /// Keeps the button in the layout so nothing below it shifts; it is just invisible and inert.
  func setSecondaryButtonVisible(_ isVisible: Bool) {
    secondaryButton.alphaValue = isVisible ? 1 : 0
    secondaryButton.isEnabled = isVisible
  }

  /// Hidden while dragging so the instructions stand alone. Unlike the buttons, this block leaves
  /// the layout entirely; the window is then resized to match.
  func setVisuallyCompleteVisible(_ isVisible: Bool) {
    visuallyCompleteStack.isHidden = !isVisible
    visuallyCompleteCheckbox.isEnabled = isVisible
    relaunchButton.isEnabled = isVisible && relaunchButton.alphaValue > 0
  }

  /// The button keeps its slot so the primary button never moves; it is only shown when a relaunch
  /// is the next step.
  func setRelaunchButtonVisible(_ isVisible: Bool) {
    relaunchButton.alphaValue = isVisible ? 1 : 0
    relaunchButton.isEnabled = isVisible && !visuallyCompleteStack.isHidden
  }

  /// Resizes the icon in place: it stays centered in its fixed container, so nothing translates.
  func setIconSize(_ size: CGFloat, animated: Bool) {
    guard iconSizeConstraint?.constant != size else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated ? 0.3 : 0
      context.allowsImplicitAnimation = true
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      iconSizeConstraint?.constant = size
      iconContainer.layoutSubtreeIfNeeded()
    }
  }

  /// Fades the checkmark in while it grows to its final size, centered on the icon. No overshoot.
  func setCheckmarkVisible(_ isVisible: Bool, animated: Bool = false) {
    guard isVisible else {
      checkmarkView.alphaValue = 0
      checkmarkSizeConstraint?.constant = 0
      return
    }
    guard animated else {
      checkmarkView.alphaValue = 1
      checkmarkSizeConstraint?.constant = 64
      iconContainer.layoutSubtreeIfNeeded()
      return
    }

    checkmarkSizeConstraint?.constant = 24
    iconContainer.layoutSubtreeIfNeeded()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.allowsImplicitAnimation = true
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      checkmarkView.animator().alphaValue = 1
      checkmarkSizeConstraint?.constant = 64
      iconContainer.layoutSubtreeIfNeeded()
    }
  }
}

/// The granted checkmark. A plain layer whose contents scale with its bounds, so an animated
/// resize grows from the center instead of from a corner like a redrawn image view would.
@MainActor
private final class CheckmarkView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.contentsGravity = .resizeAspect
    layer?.contents = Self.renderImage()
    setAccessibilityLabel("Granted")
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    layer?.contentsScale = window?.backingScaleFactor ?? 2
  }

  private static func renderImage() -> CGImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
      .applying(.init(paletteColors: [.white, .systemGreen]))
    guard let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
    else { return nil }

    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(image.size.width * scale),
      pixelsHigh: Int(image.size.height * scale),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmap.size = image.size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.cgImage
  }
}

/// The app icon as a drag source: dropping it on the permission list in System Settings adds the app.
@MainActor
private final class DraggableAppIconView: NSImageView, NSDraggingSource {
  private var mouseDownLocation: NSPoint?

  override func mouseDown(with event: NSEvent) {
    mouseDownLocation = event.locationInWindow
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownLocation, let image else { return }
    let travelled = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
    guard travelled >= 4 else { return }
    mouseDownLocation = nil

    // Rendered at the drag frame's size on demand, so the drag image is rasterized at the screen's
    // scale instead of at the source image's nominal size and then scaled up.
    let dragImage = NSImage(size: bounds.size, flipped: false) { rect in
      image.draw(in: rect)
      return true
    }
    let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    item.setDraggingFrame(bounds, contents: dragImage)
    let session = beginDraggingSession(with: [item], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  override func mouseUp(with event: NSEvent) {
    mouseDownLocation = nil
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .generic] : []
  }
}
