internal import AppKit
internal import CoreGraphics

@MainActor
enum ScreenRecordingPermission {
  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  @discardableResult
  static func promptIfNeeded() -> Bool {
    isGranted || CGRequestScreenCaptureAccess()
  }

  static func openSystemSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    ) else { return }
    NSWorkspace.shared.open(url)
  }
}
