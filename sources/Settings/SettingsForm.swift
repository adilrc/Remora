internal import AppKit

/// Builders for the grouped, System Settings-like forms used by the settings panes.
@MainActor
enum SettingsForm {
  static let pageInset: CGFloat = 20
  static let contentWidth: CGFloat = 480
  static let rowHorizontalPadding: CGFloat = 12
  static let rowVerticalPadding: CGFloat = 9
  static let rowSpacing: CGFloat = 12

  /// A scrollable page holding `sections` from top to bottom.
  static func page(_ sections: [NSView]) -> NSView {
    let stack = NSStackView(views: sections)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false

    let document = FlippedView()
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: pageInset),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: pageInset),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -pageInset),
      stack.widthAnchor.constraint(equalToConstant: contentWidth),
      document.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor, constant: pageInset * 2),
    ])

    let scrollView = NSScrollView()
    scrollView.documentView = document
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.automaticallyAdjustsContentInsets = true
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
    ])
    return scrollView
  }

  /// A titled group box whose rows are separated by hairlines.
  static func section(title: String? = nil, footer: String? = nil, rows: [NSView]) -> NSView {
    var arranged: [NSView] = []
    for (index, row) in rows.enumerated() {
      if index > 0 {
        arranged.append(separator())
      }
      arranged.append(row)
    }
    let rowsStack = NSStackView(views: arranged)
    rowsStack.orientation = .vertical
    rowsStack.alignment = .leading
    rowsStack.spacing = 0
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    let box = GroupBoxView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(rowsStack)
    NSLayoutConstraint.activate([
      box.widthAnchor.constraint(equalToConstant: contentWidth),
      rowsStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
      rowsStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
      rowsStack.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
      rowsStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
    ])

    var views: [NSView] = []
    if let title {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: 13, weight: .semibold)
      views.append(label)
    }
    views.append(box)
    if let footer {
      views.append(caption(footer, width: contentWidth - 4))
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    if views.count > 1 {
      stack.setCustomSpacing(8, after: views[views.count - 2])
    }
    return stack
  }

  /// A row with a title (and optional explanation) on the left and `control` on the right.
  /// The text column takes whatever width the control leaves; the control sits at the trailing edge.
  static func row(title: String, subtitle: String? = nil, control: NSView? = nil) -> NSView {
    let text = textStack(title: title, subtitle: subtitle)
    text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var views = [text]
    if let control {
      control.setContentHuggingPriority(.required, for: .horizontal)
      control.setContentCompressionResistancePriority(.required, for: .horizontal)
      views.append(control)
    }
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = subtitle == nil ? .centerY : .top
    stack.spacing = rowSpacing
    stack.distribution = .fill
    return padded(stack)
  }

  /// A row whose content spans the full width.
  static func row(content: NSView) -> NSView {
    padded(content)
  }

  /// A wrapping secondary label. `width` is a maximum; the label wraps to whatever width it gets.
  static func caption(_ text: String, width: CGFloat) -> NSTextField {
    let label = WrappingLabel(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = width
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
    return label
  }

  static func textStack(title: String, subtitle: String?) -> NSView {
    let maximumWidth = contentWidth - 2 - (rowHorizontalPadding * 2)
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    var views: [NSView] = [titleLabel]
    if let subtitle {
      views.append(caption(subtitle, width: maximumWidth))
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    return stack
  }
}

// MARK: - Private functionality

private extension SettingsForm {
  static func padded(_ view: NSView) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowHorizontalPadding),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rowHorizontalPadding),
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: rowVerticalPadding),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -rowVerticalPadding),
      container.widthAnchor.constraint(equalToConstant: contentWidth - 2),
    ])
    return container
  }

  static func separator() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    let container = NSView()
    line.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(line)
    NSLayoutConstraint.activate([
      line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowHorizontalPadding),
      line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      line.topAnchor.constraint(equalTo: container.topAnchor),
      line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.heightAnchor.constraint(equalToConstant: 1),
      container.widthAnchor.constraint(equalToConstant: contentWidth - 2),
    ])
    return container
  }
}

@MainActor
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A wrapping label whose height follows the width Auto Layout actually gives it.
@MainActor
private final class WrappingLabel: NSTextField {
  override func layout() {
    super.layout()
    let width = bounds.width
    guard width > 0, preferredMaxLayoutWidth != width else { return }
    preferredMaxLayoutWidth = width
    invalidateIntrinsicContentSize()
  }
}

/// Rounded, hairline-bordered container; colors follow the current appearance.
@MainActor
private final class GroupBoxView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }
}

/// A numeric field that reports a value once editing ends.
@MainActor
final class ThresholdField: NSTextField, NSTextFieldDelegate {
  /// Nil when the field is left empty, which disables that level.
  var onCommit: ((Double?) -> Void)?

  var value: Double? {
    get { stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : doubleValue }
    set {
      if let newValue {
        doubleValue = newValue
      } else {
        stringValue = ""
      }
    }
  }

  init() {
    super.init(frame: .zero)
    let numberFormatter = NumberFormatter()
    numberFormatter.numberStyle = .decimal
    numberFormatter.minimum = 0
    numberFormatter.maximumFractionDigits = 2
    formatter = numberFormatter
    placeholderString = "none"
    alignment = .right
    font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    controlSize = .small
    delegate = self
    widthAnchor.constraint(equalToConstant: 56).isActive = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    onCommit?(value)
  }
}
