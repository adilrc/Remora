import AppKit
import ApplicationServices

@MainActor
enum AccessibilityPermission {
  /// The name System Settings gives this permission on the running macOS version.
  ///
  /// macOS 27 renamed the pane from "Accessibility" to "Device Control and Data Access". It is the
  /// same permission — the TCC service and the `Privacy_Accessibility` deeplink are unchanged — so
  /// only copy the user reads should go through this.
  static var displayName: String {
    if #available(macOS 27, *) {
      return "Device Control and Data Access"
    }

    return "Accessibility"
  }

  static var isGranted: Bool {
    AXIsProcessTrusted()
  }

  static func openSystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
