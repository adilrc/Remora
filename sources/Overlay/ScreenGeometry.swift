import AppKit
import CoreGraphics

enum ScreenGeometry {
  /// Converts a Quartz / Accessibility rect (origin at the upper-left of the main display)
  /// into Cocoa screen coordinates (origin at the lower-left of the main display).
  static func cocoaRect(fromQuartz quartz: CGRect) -> CGRect {
    guard let primary = NSScreen.screens.first else { return quartz }
    var rect = quartz
    rect.origin.y = primary.frame.maxY - quartz.origin.y - quartz.height
    return rect
  }
}
