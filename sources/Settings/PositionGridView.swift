internal import AppKit

/// A miniature window with the six HUD anchor slots. Click a slot to select it.
@MainActor
final class PositionGridView: NSView {
  var selection: AppSettings.HUDPosition = .bottomRight {
    didSet { needsDisplay = true }
  }

  var isEnabled = true {
    didSet {
      alphaValue = isEnabled ? 1 : 0.4
      needsDisplay = true
    }
  }

  var onChange: ((AppSettings.HUDPosition) -> Void)?

  private var hovered: AppSettings.HUDPosition? {
    didSet { if hovered != oldValue { needsDisplay = true } }
  }

  private var trackingArea: NSTrackingArea?

  override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 112) }
  override var isFlipped: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    guard isEnabled else { return }
    hovered = anchor(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    hovered = nil
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let anchor = anchor(at: convert(event.locationInWindow, from: nil)) else { return }
    selection = anchor
    onChange?(anchor)
  }

  override func draw(_ dirtyRect: NSRect) {
    let windowRect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let windowPath = NSBezierPath(roundedRect: windowRect, xRadius: 8, yRadius: 8)
    NSColor.quaternarySystemFill.setFill()
    windowPath.fill()
    NSColor.separatorColor.setStroke()
    windowPath.stroke()

    // Title bar.
    NSGraphicsContext.saveGraphicsState()
    let titleBar = NSRect(x: windowRect.minX, y: windowRect.minY, width: windowRect.width, height: 18)
    NSBezierPath(rect: titleBar).addClip()
    NSColor.quaternarySystemFill.setFill()
    windowPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
      let dot = NSRect(x: windowRect.minX + 7 + (CGFloat(index) * 10), y: windowRect.minY + 6, width: 6, height: 6)
      color.withAlphaComponent(0.8).setFill()
      NSBezierPath(ovalIn: dot).fill()
    }
    let titleSeparator = NSBezierPath()
    titleSeparator.move(to: NSPoint(x: windowRect.minX, y: windowRect.minY + 18.5))
    titleSeparator.line(to: NSPoint(x: windowRect.maxX, y: windowRect.minY + 18.5))
    NSColor.separatorColor.setStroke()
    titleSeparator.stroke()

    for anchor in AppSettings.HUDPosition.allCases {
      let slot = slotRect(for: anchor)
      let path = NSBezierPath(roundedRect: slot, xRadius: 4, yRadius: 4)
      if anchor == selection {
        NSColor.controlAccentColor.setFill()
        path.fill()
      } else if anchor == hovered {
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        path.fill()
      } else {
        NSColor.tertiaryLabelColor.setFill()
        path.fill()
      }
    }
  }
}

// MARK: - Private functionality

private extension PositionGridView {
  var slotSize: NSSize { NSSize(width: 34, height: 16) }

  /// Slots mirror `HUDWindow`’s anchors: three columns, top row under the title bar, bottom row at the bottom.
  func slotRect(for anchor: AppSettings.HUDPosition) -> NSRect {
    let inset: CGFloat = 8
    let contentTop: CGFloat = 18 + inset
    let x: CGFloat = switch anchor.column {
    case 0: inset
    case 1: (bounds.width - slotSize.width) / 2
    default: bounds.width - inset - slotSize.width
    }
    let y = anchor.isTop ? contentTop : bounds.height - inset - slotSize.height
    return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: slotSize)
  }

  func anchor(at point: NSPoint) -> AppSettings.HUDPosition? {
    AppSettings.HUDPosition.allCases.min { lhs, rhs in
      distance(from: point, to: slotRect(for: lhs)) < distance(from: point, to: slotRect(for: rhs))
    }
  }

  func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
    hypot(point.x - rect.midX, point.y - rect.midY)
  }
}
