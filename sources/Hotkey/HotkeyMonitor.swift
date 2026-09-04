import AppKit
import Carbon.HIToolbox
import Foundation

struct KeyboardShortcut: Equatable, Sendable {
  var keyCode: UInt16
  var modifiers: NSEvent.ModifierFlags

  static let defaultToggle = KeyboardShortcut(
    keyCode: 4, // H
    modifiers: [.control, .option]
  )

  var displayString: String {
    modifiers.hotkeySymbols + keyCode.hotkeyLabel
  }

  var carbonModifiers: UInt32 {
    var value: UInt32 = 0
    if modifiers.contains(.command) { value |= UInt32(cmdKey) }
    if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
    if modifiers.contains(.option) { value |= UInt32(optionKey) }
    if modifiers.contains(.control) { value |= UInt32(controlKey) }
    return value
  }


  var configurationString: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("cmd") }
    parts.append(keyCode.configurationLabel)
    return parts.joined(separator: "+")
  }

  init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    self.keyCode = keyCode
    self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
  }


  init?(configurationString: String) {
    let parts = configurationString
      .lowercased()
      .split(separator: "+")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard parts.count >= 2, let keyName = parts.last,
          let keyCode = UInt16.keyCode(forConfigurationLabel: keyName)
    else { return nil }

    var modifiers: NSEvent.ModifierFlags = []
    for modifier in parts.dropLast() {
      switch modifier {
      case "ctrl", "control": modifiers.insert(.control)
      case "alt", "opt", "option": modifiers.insert(.option)
      case "shift": modifiers.insert(.shift)
      case "cmd", "command", "super": modifiers.insert(.command)
      default: return nil
      }
    }
    guard !modifiers.isEmpty else { return nil }
    self.init(keyCode: keyCode, modifiers: modifiers)
  }
}

@MainActor
final class HotkeyMonitor {
  var onPressed: (() -> Void)?

  private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
  private nonisolated(unsafe) var handlerRef: EventHandlerRef?
  func setShortcut(_ shortcut: KeyboardShortcut?) {
    unregister()
    guard let shortcut, shortcut.carbonModifiers != 0 else { return }
    register(shortcut)
  }

  private func register(_ shortcut: KeyboardShortcut) {
    let hotKeyID = EventHotKeyID(signature: FourCharCode("RMRA"), id: 1)
    var hotKey: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode),
      shortcut.carbonModifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard status == noErr, let hotKey else { return }
    hotKeyRef = hotKey

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let monitor = Unmanaged.passUnretained(self).toOpaque()
    var handler: EventHandlerRef?
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      hotkeyEventHandler,
      1,
      &eventType,
      monitor,
      &handler
    )
    if installed == noErr {
      handlerRef = handler
    }
  }

  private func unregister() {
    if let handlerRef {
      RemoveEventHandler(handlerRef)
      self.handlerRef = nil
    }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
  }

  func handlePress() {
    onPressed?()
  }

  deinit {
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
  }
}

private func hotkeyEventHandler(
  nextHandler: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
  DispatchQueue.main.async {
    monitor.handlePress()
  }
  return noErr
}

extension FourCharCode {
  init(_ string: String) {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
      result = (result << 8) + FourCharCode(scalar.value)
    }
    self = result
  }
}

extension NSEvent.ModifierFlags {
  var hotkeySymbols: String {
    var text = ""
    if contains(.control) { text += "⌃" }
    if contains(.option) { text += "⌥" }
    if contains(.shift) { text += "⇧" }
    if contains(.command) { text += "⌘" }
    return text
  }
}

extension UInt16 {
  var hotkeyLabel: String {
    switch self {
    case 36: return "↩"
    case 48: return "⇥"
    case 49: return "Space"
    case 51: return "⌫"
    case 53: return "⎋"
    case 117: return "⌦"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default:
      return Self.letter(for: self) ?? "Key \(self)"
    }
  }

  private static func letter(for keyCode: UInt16) -> String? {
    keyLabels[keyCode]
  }

  var configurationLabel: String {
    switch self {
    case 36: return "enter"
    case 48: return "tab"
    case 49: return "space"
    case 51: return "backspace"
    case 53: return "escape"
    case 117: return "delete"
    case 123: return "left"
    case 124: return "right"
    case 125: return "down"
    case 126: return "up"
    default: return Self.letter(for: self)?.lowercased() ?? String(self)
    }
  }

  static func keyCode(forConfigurationLabel label: String) -> UInt16? {
    let aliases: [String: UInt16] = [
      "enter": 36, "return": 36, "tab": 48, "space": 49,
      "backspace": 51, "escape": 53, "esc": 53, "delete": 117,
      "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    if let keyCode = aliases[label] { return keyCode }
    return keyLabels.first(where: { $0.value.lowercased() == label })?.key
  }

  private static let keyLabels: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
    38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "N", 46: "M", 47: ".", 50: "`",
  ]
}
