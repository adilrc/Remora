internal import Foundation
private import os

private let settingsLog = Logger(subsystem: "com.remora.app", category: "configuration")

/// Values at or above `orange` are shown in orange, values at or above `red` in red. Either level
/// can be absent; a metric with neither is always drawn in the label color.
struct MetricThresholds: Equatable, Sendable {
  var orange: Double?
  var red: Double?

  static let none = MetricThresholds(orange: nil, red: nil)

  /// Only CPU and Energy Impact color themselves out of the box.
  static func defaults(for metric: HUDMetric) -> MetricThresholds {
    switch metric {
    case .cpu: MetricThresholds(orange: 40, red: 80)
    case .energyImpact: MetricThresholds(orange: 100, red: 200)
    default: .none
    }
  }

  init(orange: Double?, red: Double?) {
    self.orange = orange
    if let orange, let red {
      self.red = max(red, orange)
    } else {
      self.red = red
    }
  }
}

/// How often CPU, memory and Energy Impact are published. CPU and Energy are averaged over the
/// same window, so a longer interval means steadier numbers.
enum RefreshInterval: Int, CaseIterable, Sendable {
  case oneSecond = 1
  case twoSeconds = 2
  case fiveSeconds = 5
  case tenSeconds = 10

  var seconds: TimeInterval { TimeInterval(rawValue) }

  var title: String {
    rawValue == 1 ? "1 second" : "\(rawValue) seconds"
  }

  /// The closest supported interval for a configured number of seconds.
  init(nearest seconds: Double) {
    self = Self.allCases.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .fiveSeconds
  }
}

@MainActor
final class AppSettings {
  static let shared = AppSettings()

  enum Change: Sendable {
    case position
    case isDetached
    case followsActiveWindow
    case excludedBundleIdentifiers
    case metricOrder
    case showsCPU
    case showsMemory
    case showsEnergyImpact
    case showsTwelveHourPower
    case showsLaunchTimer
    case showsTimeToInteractive
    case thresholds
    case refreshInterval
    case toggleShortcut
  }

  enum HUDPosition: String, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case bottomLeft
    case bottom
    case bottomRight

    var configurationValue: String {
      switch self {
      case .topLeft: "top-left"
      case .top: "top"
      case .topRight: "top-right"
      case .bottomLeft: "bottom-left"
      case .bottom: "bottom"
      case .bottomRight: "bottom-right"
      }
    }

    var title: String {
      switch self {
      case .topLeft: "Top Left"
      case .top: "Top"
      case .topRight: "Top Right"
      case .bottomLeft: "Bottom Left"
      case .bottom: "Bottom"
      case .bottomRight: "Bottom Right"
      }
    }

    var isTop: Bool {
      switch self {
      case .topLeft, .top, .topRight: true
      case .bottomLeft, .bottom, .bottomRight: false
      }
    }

    /// 0 = leading, 1 = center, 2 = trailing.
    var column: Int {
      switch self {
      case .topLeft, .bottomLeft: 0
      case .top, .bottom: 1
      case .topRight, .bottomRight: 2
      }
    }

    init?(configurationValue: String) {
      let normalized = configurationValue.lowercased().replacingOccurrences(of: "_", with: "-")
      guard let match = Self.allCases.first(where: {
        $0.configurationValue == normalized || $0.rawValue.lowercased() == normalized
      }) else { return nil }
      self = match
    }
  }

  var position: HUDPosition {
    didSet { settingDidChange(.position, key: "hud-position", value: position.configurationValue) }
  }

  var isDetached: Bool {
    didSet { settingDidChange(.isDetached, key: "hud-detached", value: Self.text(isDetached)) }
  }

  /// Screen origin of the HUD while detached, in Cocoa coordinates. Nil until the HUD is first detached.
  /// Positional UI state, so it lives in UserDefaults rather than the configuration file.
  var detachedOrigin: CGPoint? {
    get {
      guard defaults.object(forKey: Self.detachedOriginXKey) != nil,
            defaults.object(forKey: Self.detachedOriginYKey) != nil
      else { return nil }
      return CGPoint(x: defaults.double(forKey: Self.detachedOriginXKey), y: defaults.double(forKey: Self.detachedOriginYKey))
    }
    set {
      if let newValue {
        defaults.set(Double(newValue.x), forKey: Self.detachedOriginXKey)
        defaults.set(Double(newValue.y), forKey: Self.detachedOriginYKey)
      } else {
        defaults.removeObject(forKey: Self.detachedOriginXKey)
        defaults.removeObject(forKey: Self.detachedOriginYKey)
      }
    }
  }

  /// When false the HUD stays on the app it is showing until “Attach to Active Window” is used.
  var followsActiveWindow: Bool {
    didSet { settingDidChange(.followsActiveWindow, key: "follow-active-window", value: Self.text(followsActiveWindow)) }
  }

  /// Bundle identifiers of apps the HUD never shows on.
  var excludedBundleIdentifiers: [String] {
    didSet {
      excludedBundleIdentifiers = Self.normalizedBundleIdentifiers(excludedBundleIdentifiers)
      guard excludedBundleIdentifiers != oldValue else { return }
      settingDidChange(.excludedBundleIdentifiers, key: "excluded-apps", value: excludedBundleIdentifiers.joined(separator: ","))
    }
  }

  /// Every metric exactly once, in display order.
  var metricOrder: [HUDMetric] {
    didSet {
      metricOrder = Self.normalizedMetricOrder(metricOrder)
      guard metricOrder != oldValue else { return }
      settingDidChange(.metricOrder, key: "metric-order", value: Self.text(metricOrder))
    }
  }

  var showsCPU: Bool {
    didSet { settingDidChange(.showsCPU, key: "show-cpu", value: Self.text(showsCPU)) }
  }

  var showsMemory: Bool {
    didSet { settingDidChange(.showsMemory, key: "show-memory", value: Self.text(showsMemory)) }
  }

  var showsEnergyImpact: Bool {
    didSet { settingDidChange(.showsEnergyImpact, key: "show-energy-impact", value: Self.text(showsEnergyImpact)) }
  }

  var showsTwelveHourPower: Bool {
    didSet { settingDidChange(.showsTwelveHourPower, key: "show-twelve-hour-power", value: Self.text(showsTwelveHourPower)) }
  }

  var showsLaunchTimer: Bool {
    didSet { settingDidChange(.showsLaunchTimer, key: "show-launch-timer", value: Self.text(showsLaunchTimer)) }
  }

  var showsTimeToInteractive: Bool {
    didSet {
      settingDidChange(
        .showsTimeToInteractive,
        key: "show-time-to-interactive",
        value: Self.text(showsTimeToInteractive)
      )
    }
  }

  /// Color thresholds per metric. Every metric has an entry; most are `.none` by default.
  var thresholds: [HUDMetric: MetricThresholds] {
    didSet {
      for metric in HUDMetric.allCases where thresholds[metric] != oldValue[metric] {
        let value = thresholds[metric] ?? .none
        settingDidChange(.thresholds, key: Self.orangeKey(for: metric), value: Self.text(value.orange))
        settingDidChange(.thresholds, key: Self.redKey(for: metric), value: Self.text(value.red))
      }
    }
  }

  func thresholds(for metric: HUDMetric) -> MetricThresholds {
    thresholds[metric] ?? .none
  }

  func setThresholds(_ value: MetricThresholds, for metric: HUDMetric) {
    thresholds[metric] = value
  }

  var refreshInterval: RefreshInterval {
    didSet { settingDidChange(.refreshInterval, key: "refresh-interval", value: String(refreshInterval.rawValue)) }
  }

  var toggleShortcut: KeyboardShortcut? {
    didSet { settingDidChange(.toggleShortcut, key: "toggle-shortcut", value: toggleShortcut?.configurationString ?? "none") }
  }

  var hasVisibleMetric: Bool {
    showsCPU
      || showsMemory
      || showsEnergyImpact
      || showsTwelveHourPower
      || showsLaunchTimer
      || showsTimeToInteractive
  }

  var configurationURL: URL { configuration.url }

  private static let detachedOriginXKey = "hud.detachedOrigin.x"
  private static let detachedOriginYKey = "hud.detachedOrigin.y"

  private let configuration: ConfigurationFile
  private let defaults = UserDefaults.standard
  private var isApplyingConfiguration = false
  private var monitorTimer: Timer?
  private var observers: [ObjectIdentifier: AppSettingsObserver] = [:]

  private init() {
    let configuration = ConfigurationFile()
    self.configuration = configuration

    var initial = Values.defaults
    if configuration.exists {
      do {
        initial = Self.values(from: try configuration.load())
        try configuration.addMissingValues(initial.configurationValues)
      } catch {
        settingsLog.error("Unable to read configuration: \(error.localizedDescription, privacy: .public)")
      }
    } else {
      do {
        try configuration.create(with: initial.configurationValues)
      } catch {
        settingsLog.error("Unable to create configuration: \(error.localizedDescription, privacy: .public)")
      }
    }

    position = initial.position
    isDetached = initial.isDetached
    followsActiveWindow = initial.followsActiveWindow
    excludedBundleIdentifiers = initial.excludedBundleIdentifiers
    metricOrder = initial.metricOrder
    showsCPU = initial.showsCPU
    showsMemory = initial.showsMemory
    showsEnergyImpact = initial.showsEnergyImpact
    showsTwelveHourPower = initial.showsTwelveHourPower
    showsLaunchTimer = initial.showsLaunchTimer
    showsTimeToInteractive = initial.showsTimeToInteractive
    thresholds = initial.thresholds
    refreshInterval = initial.refreshInterval
    toggleShortcut = initial.toggleShortcut
  }

  func startMonitoring() {
    guard monitorTimer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reloadIfNeeded() }
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    monitorTimer = timer
  }

  func observe(_ owner: AnyObject, handler: @escaping @MainActor (Change) -> Void) {
    observers[ObjectIdentifier(owner)] = AppSettingsObserver(owner: owner, handler: handler)
  }

  func removeObserver(_ owner: AnyObject) {
    observers.removeValue(forKey: ObjectIdentifier(owner))
  }

  func reload() {
    do {
      apply(Self.values(from: try configuration.load()))
    } catch {
      settingsLog.error("Unable to reload configuration: \(error.localizedDescription, privacy: .public)")
    }
  }
}

// MARK: - Private functionality

private extension AppSettings {
  func reloadIfNeeded() {
    guard configuration.exists else {
      do {
        try configuration.create(with: currentValues.configurationValues)
      } catch {
        settingsLog.error("Unable to recreate configuration: \(error.localizedDescription, privacy: .public)")
      }
      return
    }

    do {
      guard let contents = try configuration.contentsIfChanged() else { return }
      apply(Self.values(from: contents))
    } catch {
      settingsLog.error("Unable to watch configuration: \(error.localizedDescription, privacy: .public)")
    }
  }

  func apply(_ values: Values) {
    isApplyingConfiguration = true
    position = values.position
    isDetached = values.isDetached
    followsActiveWindow = values.followsActiveWindow
    excludedBundleIdentifiers = values.excludedBundleIdentifiers
    metricOrder = values.metricOrder
    showsCPU = values.showsCPU
    showsMemory = values.showsMemory
    showsEnergyImpact = values.showsEnergyImpact
    showsTwelveHourPower = values.showsTwelveHourPower
    showsLaunchTimer = values.showsLaunchTimer
    showsTimeToInteractive = values.showsTimeToInteractive
    thresholds = values.thresholds
    refreshInterval = values.refreshInterval
    toggleShortcut = values.toggleShortcut
    isApplyingConfiguration = false
  }

  func settingDidChange(_ change: Change, key: String, value: String) {
    if !isApplyingConfiguration {
      save(key, value)
    }
    notifyObservers(of: change)
  }

  func save(_ key: String, _ value: String) {
    do {
      try configuration.set(key, to: value)
    } catch {
      settingsLog.error("Unable to save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  func notifyObservers(of change: Change) {
    observers = observers.filter { $0.value.owner != nil }
    for observer in observers.values {
      observer.handler(change)
    }
  }

  var currentValues: Values {
    Values(
      position: position,
      isDetached: isDetached,
      followsActiveWindow: followsActiveWindow,
      excludedBundleIdentifiers: excludedBundleIdentifiers,
      metricOrder: metricOrder,
      showsCPU: showsCPU,
      showsMemory: showsMemory,
      showsEnergyImpact: showsEnergyImpact,
      showsTwelveHourPower: showsTwelveHourPower,
      showsLaunchTimer: showsLaunchTimer,
      showsTimeToInteractive: showsTimeToInteractive,
      thresholds: thresholds,
      refreshInterval: refreshInterval,
      toggleShortcut: toggleShortcut
    )
  }

  static func values(from contents: String) -> Values {
    let values = ConfigurationFile.values(in: contents)
    var result = Values.defaults
    if let value = values["hud-position"], let position = HUDPosition(configurationValue: value) {
      result.position = position
    }
    result.isDetached = configuredBool("hud-detached", in: values) ?? result.isDetached
    result.followsActiveWindow = configuredBool("follow-active-window", in: values) ?? result.followsActiveWindow
    if let value = values["excluded-apps"] {
      result.excludedBundleIdentifiers = normalizedBundleIdentifiers(value.split(separator: ",").map(String.init))
    }
    if let value = values["metric-order"] {
      result.metricOrder = normalizedMetricOrder(value.split(separator: ",").compactMap {
        HUDMetric(configurationValue: String($0))
      })
    }
    result.showsCPU = configuredBool("show-cpu", in: values) ?? result.showsCPU
    result.showsMemory = configuredBool("show-memory", in: values) ?? result.showsMemory
    result.showsEnergyImpact = configuredBool("show-energy-impact", in: values) ?? result.showsEnergyImpact
    result.showsTwelveHourPower = configuredBool("show-twelve-hour-power", in: values) ?? result.showsTwelveHourPower
    result.showsLaunchTimer = configuredBool("show-launch-timer", in: values) ?? result.showsLaunchTimer
    result.showsTimeToInteractive = configuredBool("show-time-to-interactive", in: values)
      ?? result.showsTimeToInteractive
    for metric in HUDMetric.allCases {
      result.thresholds[metric] = configuredThresholds(
        for: metric,
        in: values,
        fallback: result.thresholds[metric] ?? .none
      )
    }
    if let value = values["refresh-interval"].flatMap(Double.init) {
      result.refreshInterval = RefreshInterval(nearest: value)
    }
    if let value = values["toggle-shortcut"] {
      if value.lowercased() == "none" {
        result.toggleShortcut = nil
      } else if let shortcut = KeyboardShortcut(configurationString: value) {
        result.toggleShortcut = shortcut
      }
    }
    return result
  }

  static func bool(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "true", "yes", "on", "1": true
    case "false", "no", "off", "0": false
    default: nil
    }
  }

  static func configuredBool(_ key: String, in values: [String: String]) -> Bool? {
    values[key].flatMap { bool($0) }
  }

  nonisolated static func orangeKey(for metric: HUDMetric) -> String { "\(metric.configurationValue)-orange-threshold" }
  nonisolated static func redKey(for metric: HUDMetric) -> String { "\(metric.configurationValue)-red-threshold" }

  /// A missing key keeps the fallback; `none` (or any non-number) clears the level.
  static func configuredThresholds(
    for metric: HUDMetric,
    in values: [String: String],
    fallback: MetricThresholds
  ) -> MetricThresholds {
    func level(_ key: String, fallback: Double?) -> Double? {
      guard let raw = values[key] else { return fallback }
      return Double(raw)
    }
    return MetricThresholds(
      orange: level(orangeKey(for: metric), fallback: fallback.orange),
      red: level(redKey(for: metric), fallback: fallback.red)
    )
  }

  nonisolated static func text(_ value: Bool) -> String {
    value ? "true" : "false"
  }

  nonisolated static func text(_ value: [HUDMetric]) -> String {
    value.map(\.configurationValue).joined(separator: ",")
  }

  nonisolated static func normalizedBundleIdentifiers(_ identifiers: [String]) -> [String] {
    var result: [String] = []
    for identifier in identifiers {
      let trimmed = identifier.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty, !result.contains(trimmed) {
        result.append(trimmed)
      }
    }
    return result
  }

  /// Drops duplicates and appends any metric that is missing, in default order.
  nonisolated static func normalizedMetricOrder(_ order: [HUDMetric]) -> [HUDMetric] {
    var result: [HUDMetric] = []
    for metric in order + HUDMetric.allCases where !result.contains(metric) {
      result.append(metric)
    }
    return result
  }

  nonisolated static func text(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  nonisolated static func text(_ value: Double?) -> String {
    value.map(text) ?? "none"
  }

  struct Values {
    var position: HUDPosition
    var isDetached: Bool
    var followsActiveWindow: Bool
    var excludedBundleIdentifiers: [String]
    var metricOrder: [HUDMetric]
    var showsCPU: Bool
    var showsMemory: Bool
    var showsEnergyImpact: Bool
    var showsTwelveHourPower: Bool
    var showsLaunchTimer: Bool
    var showsTimeToInteractive: Bool
    var thresholds: [HUDMetric: MetricThresholds]
    var refreshInterval: RefreshInterval
    var toggleShortcut: KeyboardShortcut?

    static let defaults = Values(
      position: .bottomRight,
      isDetached: false,
      followsActiveWindow: true,
      excludedBundleIdentifiers: [],
      metricOrder: HUDMetric.allCases,
      showsCPU: true,
      showsMemory: true,
      showsEnergyImpact: true,
      showsTwelveHourPower: true,
      showsLaunchTimer: false,
      showsTimeToInteractive: false,
      thresholds: Dictionary(uniqueKeysWithValues: HUDMetric.allCases.map { ($0, MetricThresholds.defaults(for: $0)) }),
      refreshInterval: .fiveSeconds,
      toggleShortcut: .defaultToggle
    )

    var configurationValues: [String: String] {
      var thresholdValues: [String: String] = [:]
      for metric in HUDMetric.allCases {
        let value = thresholds[metric] ?? .none
        thresholdValues[AppSettings.orangeKey(for: metric)] = AppSettings.text(value.orange)
        thresholdValues[AppSettings.redKey(for: metric)] = AppSettings.text(value.red)
      }
      return thresholdValues.merging([
        "hud-position": position.configurationValue,
        "hud-detached": AppSettings.text(isDetached),
        "follow-active-window": AppSettings.text(followsActiveWindow),
        "excluded-apps": excludedBundleIdentifiers.joined(separator: ","),
        "metric-order": AppSettings.text(metricOrder),
        "show-cpu": AppSettings.text(showsCPU),
        "show-memory": AppSettings.text(showsMemory),
        "show-energy-impact": AppSettings.text(showsEnergyImpact),
        "show-twelve-hour-power": AppSettings.text(showsTwelveHourPower),
        "show-launch-timer": AppSettings.text(showsLaunchTimer),
        "show-time-to-interactive": AppSettings.text(showsTimeToInteractive),
        "refresh-interval": String(refreshInterval.rawValue),
        "toggle-shortcut": toggleShortcut?.configurationString ?? "none",
      ]) { _, new in new }
    }
  }
}

@MainActor
private final class AppSettingsObserver {
  weak var owner: AnyObject?
  let handler: @MainActor (AppSettings.Change) -> Void

  init(owner: AnyObject, handler: @escaping @MainActor (AppSettings.Change) -> Void) {
    self.owner = owner
    self.handler = handler
  }
}
