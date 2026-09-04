internal import AppKit

/// Walks the user through granting the Accessibility permission. Clicking “Grant” opens System
/// Settings, slides this window next to it, and turns the app icon into a drag source so the app
/// can be dropped straight into the permission list.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

  private var window: NSWindow?
  private var onboardingView: OnboardingView?
  private var permissionTimer: Timer?
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

    if !window.isVisible {
      window.level = .normal
      window.center()
      onboardingView.stage = AccessibilityPermission.isGranted ? .granted(playSound: false) : .intro
    }
    AppActivation.windowWillShow(window)
    window.makeKeyAndOrderFront(nil)
    startPermissionPolling()
    onVisibilityChanged?(true)
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
    view.onDone = { [weak self] in self?.window?.close() }
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
    guard let window else { return }
    AccessibilityPermission.openSystemSettings()
    window.level = .floating
    onboardingView?.stage = .dragging
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
      return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsBundleIdentifier).first,
          let quartzFrame = CGWindowList.primaryWindowFrame(pid: app.processIdentifier)
    else { return }

    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
    moveWindow(nextTo: ScreenGeometry.cocoaRect(fromQuartz: quartzFrame))
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
    stopTimers()
    onboardingView?.stage = .granted(playSound: true)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func stopTimers() {
    permissionTimer?.invalidate()
    permissionTimer = nil
    settingsWindowTimer?.invalidate()
    settingsWindowTimer = nil
  }
}

@MainActor
private final class OnboardingView: NSView {
  enum Stage: Equatable {
    case intro
    case dragging
    case granted(playSound: Bool)
  }

  static let size = NSSize(width: 380, height: 400)
  static let largeIconSize: CGFloat = 140

  var onGrant: (() -> Void)?
  var onDone: (() -> Void)?

  var stage: Stage = .intro {
    didSet { apply(stage, animated: true) }
  }

  private let iconContainer = NSView()
  private let iconView = DraggableAppIconView()
  private let checkmarkView = CheckmarkView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")
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
    // as the generic placeholder for a bundle the system has not registered yet.
    iconView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
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

    let stack = NSStackView(views: [iconContainer, titleLabel, bodyLabel, primaryButton, secondaryButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.setCustomSpacing(8, after: iconContainer)
    stack.setCustomSpacing(24, after: bodyLabel)
    stack.setCustomSpacing(8, after: primaryButton)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
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
    case .granted: onDone?()
    }
  }

  @objc func secondaryAction() {
    switch stage {
    case .intro, .dragging: onDone?()
    case .granted: break
    }
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
      primaryButton.title = "Grant \(permission) Access"
      secondaryButton.title = "Not Now"
      setSecondaryButtonVisible(true)

    case .dragging:
      titleLabel.stringValue = "Drag the icon into System Settings"
      bodyLabel.stringValue = "Drop the \(appName) icon onto the \(permission) list."
      primaryButton.title = "Open System Settings Again"
      secondaryButton.title = "Not Now"
      setSecondaryButtonVisible(true)

    case .granted:
      titleLabel.stringValue = "You’re all set"
      bodyLabel.stringValue = "\(permission) access is granted. The HUD will attach to the frontmost window."
      primaryButton.title = "Done"
      setSecondaryButtonVisible(false)
    }
    layoutSubtreeIfNeeded()

    switch stage {
    case .intro:
      iconView.alphaValue = 1
      setIconSize(96, animated: animated)
      setCheckmarkVisible(false)

    case .dragging:
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

    let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    item.setDraggingFrame(bounds, contents: image)
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
