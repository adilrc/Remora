internal import Foundation

enum HUDMetric: String, CaseIterable, Sendable {
  case cpu
  case memory
  case energyImpact
  case twelveHourPower
  case launchTimer
  case timeToInteractive
  case visuallyComplete
}

extension HUDMetric {
  /// Identifier used in the configuration file’s `metric-order`.
  var configurationValue: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memory"
    case .energyImpact: "energy-impact"
    case .twelveHourPower: "twelve-hour-power"
    case .launchTimer: "launch-timer"
    case .timeToInteractive: "time-to-interactive"
    case .visuallyComplete: "visually-complete"
    }
  }

  init?(configurationValue: String) {
    let normalized = configurationValue.trimmingCharacters(in: .whitespaces).lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard let match = Self.allCases.first(where: { $0.configurationValue == normalized }) else { return nil }
    self = match
  }

  /// Full name used in menus and Settings.
  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .energyImpact: "Energy Impact"
    case .twelveHourPower: "12 hr Power"
    case .launchTimer: "Launch Timer"
    case .timeToInteractive: "Time to Interactive"
    case .visuallyComplete: "Visually Complete"
    }
  }

  /// Compact label rendered above the value in the HUD.
  var shortLabel: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "MEM"
    case .energyImpact: "ENERGY"
    case .twelveHourPower: "12H PWR"
    case .launchTimer: "LAUNCH"
    case .timeToInteractive: "TTI"
    case .visuallyComplete: "VISUAL"
    }
  }

  /// What the metric measures, shown in Settings.
  var summary: String {
    switch self {
    case .cpu:
      "Percentage of CPU used by the app and its helper processes, averaged over each refresh interval. "
      + "Matches the application row in Activity Monitor."
    case .memory:
      "Physical memory footprint of the app and its helper processes, sampled at each refresh interval."
    case .energyImpact:
      "Activity Monitor’s live Energy Impact score for the app’s resource coalition: CPU, GPU, wakeups and disk I/O "
      + "weighted with this Mac’s power coefficients. 100% CPU is roughly 100. Averaged over each refresh interval."
    case .twelveHourPower:
      "Average Energy Impact over the last 12 hours, read from the same system history Activity Monitor uses "
      + "for its 12 hr Power column."
    case .launchTimer:
      "Time from process launch until the app’s first normal window appears on screen. "
      + "Only available for apps launched while this app is running."
    case .timeToInteractive:
      "Time from process launch until the app exposes an enabled, keyboard-focused text field through Accessibility. "
      + "Apps with incomplete Accessibility support stay unavailable."
    case .visuallyComplete:
      "Time from process launch until the window's last meaningful rendered frame after Time to Interactive, "
      + "followed by 750 ms of visual stability."
    }
  }

  /// The widest value each cell reserves room for, so digits changing never shifts the layout.
  var widthTemplate: String {
    switch self {
    case .cpu: "100.0%"
    case .memory: "100.0 MB"
    case .energyImpact, .twelveHourPower: "100.0"
    case .launchTimer, .timeToInteractive, .visuallyComplete: "10.00s"
    }
  }

  /// Unit of the threshold values entered in Settings.
  var thresholdUnit: String {
    switch self {
    case .cpu: "%"
    case .memory: "MB"
    case .energyImpact, .twelveHourPower: ""
    case .launchTimer, .timeToInteractive, .visuallyComplete: "s"
    }
  }
}
