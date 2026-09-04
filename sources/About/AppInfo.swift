internal import Foundation

/// Facts about this build that the About window and menus show.
enum AppInfo {
  static var name: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? ProcessInfo.processInfo.processName
  }

  /// "0.1.0 (1)"
  static var versionDescription: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    return "\(version) (\(build))"
  }

  static var copyright: String {
    Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
  }

  static let tagline = "A performance HUD that rides on the frontmost window."

  static let repositoryURL = URL(string: "https://github.com/adilrc/Remora")!
  static let issuesURL = URL(string: "https://github.com/adilrc/Remora/issues/new")!
}
