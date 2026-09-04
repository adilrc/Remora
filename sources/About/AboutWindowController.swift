internal import AppKit

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?

  func show() {
    if window == nil {
      window = makeWindow()
    }
    guard let window else { return }
    if !window.isVisible {
      window.center()
    }
    AppActivation.windowWillShow(window)
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    if let window {
      AppActivation.windowWillClose(window)
    }
  }
}

// MARK: - Private functionality

private extension AboutWindowController {
  func makeWindow() -> NSWindow {
    let view = AboutView()
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: view.fittingSize),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "About \(AppInfo.name)"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.contentView = view
    window.delegate = self
    return window
  }
}

@MainActor
private final class AboutView: NSView {
  private static let width: CGFloat = 320

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUpView()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override var acceptsFirstResponder: Bool { true }

  /// Escape closes the window.
  override func cancelOperation(_ sender: Any?) {
    window?.close()
  }
}

// MARK: - Setup

private extension AboutView {
  func setUpView() {
    let iconView = NSImageView(image: NSApp.applicationIconImage)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 96),
      iconView.heightAnchor.constraint(equalToConstant: 96),
    ])

    let nameLabel = NSTextField(labelWithString: AppInfo.name)
    nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
    nameLabel.alignment = .center

    let versionLabel = NSTextField(labelWithString: "Version \(AppInfo.versionDescription)")
    versionLabel.font = .systemFont(ofSize: 12)
    versionLabel.textColor = .secondaryLabelColor
    versionLabel.alignment = .center
    versionLabel.isSelectable = true

    let taglineLabel = NSTextField(wrappingLabelWithString: AppInfo.tagline)
    taglineLabel.font = .systemFont(ofSize: 13)
    taglineLabel.alignment = .center
    taglineLabel.preferredMaxLayoutWidth = Self.width - 56
    taglineLabel.widthAnchor.constraint(equalToConstant: Self.width - 56).isActive = true

    let repositoryButton = NSButton(title: "GitHub", target: self, action: #selector(openRepository))
    let issuesButton = NSButton(title: "Report an Issue", target: self, action: #selector(openIssues))
    for button in [repositoryButton, issuesButton] {
      button.bezelStyle = .rounded
      button.controlSize = .regular
    }
    let links = NSStackView(views: [repositoryButton, issuesButton])
    links.orientation = .horizontal
    links.spacing = 8

    let copyrightLabel = NSTextField(labelWithString: AppInfo.copyright)
    copyrightLabel.font = .systemFont(ofSize: 11)
    copyrightLabel.textColor = .tertiaryLabelColor
    copyrightLabel.alignment = .center

    let stack = NSStackView(views: [iconView, nameLabel, versionLabel, taglineLabel, links, copyrightLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.setCustomSpacing(14, after: iconView)
    stack.setCustomSpacing(14, after: versionLabel)
    stack.setCustomSpacing(18, after: taglineLabel)
    stack.setCustomSpacing(18, after: links)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 44),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
    ])
  }

  @objc func openRepository() {
    NSWorkspace.shared.open(AppInfo.repositoryURL)
  }

  @objc func openIssues() {
    NSWorkspace.shared.open(AppInfo.issuesURL)
  }
}
