internal import Foundation

@MainActor
final class ConfigurationFile {
  static let supportedKeys = [
    "hud-position",
    "hud-detached",
    "follow-active-window",
    "excluded-apps",
    "metric-order",
    "show-cpu",
    "show-memory",
    "show-energy-impact",
    "show-twelve-hour-power",
    "show-launch-timer",
    "show-time-to-interactive",
    "show-visually-complete",
    "cpu-orange-threshold",
    "cpu-red-threshold",
    "memory-orange-threshold",
    "memory-red-threshold",
    "energy-impact-orange-threshold",
    "energy-impact-red-threshold",
    "twelve-hour-power-orange-threshold",
    "twelve-hour-power-red-threshold",
    "launch-timer-orange-threshold",
    "launch-timer-red-threshold",
    "time-to-interactive-orange-threshold",
    "time-to-interactive-red-threshold",
    "visually-complete-orange-threshold",
    "visually-complete-red-threshold",
    "refresh-interval",
    "toggle-shortcut",
  ]

  let url: URL

  /// Debug builds keep their own directory, so working on the app never touches the real configuration.
  static let directoryName: String = {
    #if DEBUG
    return "remora-dev"
    #else
    return "remora"
    #endif
  }()

  private var lastContents: String?

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    let baseURL: URL
    if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
      baseURL = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
    } else {
      baseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
    }
    url = baseURL
      .appendingPathComponent(Self.directoryName, isDirectory: true)
      .appendingPathComponent("config", isDirectory: false)
  }

  var exists: Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func load() throws -> String {
    let contents = try String(contentsOf: url, encoding: .utf8)
    lastContents = contents
    return contents
  }

  func contentsIfChanged() throws -> String? {
    let contents = try String(contentsOf: url, encoding: .utf8)
    guard contents != lastContents else { return nil }
    lastContents = contents
    return contents
  }

  func create(with values: [String: String]) throws {
    let lines = Self.supportedKeys.compactMap { key in
      values[key].map { "\(key) = \($0)" }
    }
    let contents = """
    # Remora configuration
    # Changes are reloaded automatically. Boolean values are true or false.

    \(lines.joined(separator: "\n"))
    """ + "\n"
    try write(contents)
  }

  /// Keys from earlier versions that no longer mean anything; they are removed on load.
  static let retiredKeys: Set<String> = [
    "collapse-on-hover",
    "show-visual-time-to-interactive",
    "hud-detached-position",
  ]

  func addMissingValues(_ values: [String: String]) throws {
    let contents = try String(contentsOf: url, encoding: .utf8)
    let existingValues = Self.values(in: contents)
    let missingKeys = Self.supportedKeys.filter { existingValues[$0] == nil && values[$0] != nil }
    let retiredLines = contents.components(separatedBy: "\n").filter { line in
      Self.key(in: line).map(Self.retiredKeys.contains) ?? false
    }
    guard !missingKeys.isEmpty || !retiredLines.isEmpty else { return }

    var updatedContents = contents
      .components(separatedBy: "\n")
      .filter { line in !(Self.key(in: line).map(Self.retiredKeys.contains) ?? false) }
      .joined(separator: "\n")
    if !updatedContents.isEmpty, !updatedContents.hasSuffix("\n") {
      updatedContents += "\n"
    }
    if !updatedContents.isEmpty, !updatedContents.hasSuffix("\n\n") {
      updatedContents += "\n"
    }
    for key in missingKeys {
      if let value = values[key] {
        updatedContents += "\(key) = \(value)\n"
      }
    }
    try write(updatedContents)
  }


  func set(_ key: String, to value: String) throws {
    var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var lines = contents.components(separatedBy: "\n")
    let matchingIndices = lines.indices.filter { Self.key(in: lines[$0]) == key }

    if let lastIndex = matchingIndices.last {
      let indentation = String(lines[lastIndex].prefix { $0 == " " || $0 == "\t" })
      lines[lastIndex] = "\(indentation)\(key) = \(value)"
      for index in matchingIndices.dropLast().reversed() {
        lines.remove(at: index)
      }
    } else {
      while lines.last == "" { lines.removeLast() }
      if !lines.isEmpty { lines.append("") }
      lines.append("\(key) = \(value)")
      lines.append("")
    }

    contents = lines.joined(separator: "\n")
    if !contents.hasSuffix("\n") { contents += "\n" }
    try write(contents)
  }

  static func values(in contents: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in contents.components(separatedBy: .newlines) {
      guard let key = key(in: line), supportedKeys.contains(key),
            let equals = line.firstIndex(of: "=")
      else { continue }
      let rawValue = line[line.index(after: equals)...]
      let value = rawValue.trimmingCharacters(in: .whitespaces)
      result[key] = value
    }
    return result
  }
}

// MARK: - Private functionality

private extension ConfigurationFile {
  func write(_ contents: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    lastContents = contents
  }

  static func key(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
          let equals = trimmed.firstIndex(of: "=")
    else { return nil }
    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    return key.replacingOccurrences(of: "_", with: "-")
  }
}
