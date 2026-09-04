internal import AppKit

@MainActor
final class HotkeyRecorderView: NSView {
  var shortcut: KeyboardShortcut? {
    didSet { needsDisplay = true }
  }

  var onChange: ((KeyboardShortcut?) -> Void)?

  private var isRecording = false

  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { false }
  override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 28) }

  override func draw(_ dirtyRect: NSRect) {
    let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.lineWidth = isRecording ? 2 : 1
    path.stroke()

    let title: String
    if isRecording {
      title = "Type shortcut…"
    } else if let shortcut {
      title = shortcut.displayString
    } else {
      title = "Click to record"
    }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
    ]
    let size = title.size(withAttributes: attributes)
    let origin = NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
    title.draw(at: origin, withAttributes: attributes)
  }

  override func mouseDown(with event: NSEvent) {
    isRecording = true
    window?.makeFirstResponder(self)
    needsDisplay = true
  }

  override func resignFirstResponder() -> Bool {
    isRecording = false
    needsDisplay = true
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }

    if event.keyCode == 53 {
      stopRecording()
      return
    }

    if event.keyCode == 51 || event.keyCode == 117 {
      shortcut = nil
      onChange?(nil)
      stopRecording()
      return
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])
    guard !modifiers.isEmpty else { return }

    let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
    self.shortcut = shortcut
    onChange?(shortcut)
    stopRecording()
  }

  override func flagsChanged(with event: NSEvent) {
    needsDisplay = true
  }
}

// MARK: - Private functionality

private extension HotkeyRecorderView {
  func stopRecording() {
    isRecording = false
    window?.makeFirstResponder(nil)
    needsDisplay = true
  }
}
