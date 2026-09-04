import Darwin
import Foundation

/// Activity Monitor’s 12 hr Power column: `systemstats_get_top_coalitions`.
final class SystemStatsEnergyStore: @unchecked Sendable {
  static let shared = SystemStatsEnergyStore()

  private struct Snapshot {
    var scores: [String: Double]
  }

  private let lock = NSLock()
  private var snapshot: Snapshot?
  private var lastFetch: TimeInterval = 0
  private var isFetching = false
  private let refreshInterval: TimeInterval = 30
  private let fetchQueue = DispatchQueue(label: "com.remora.systemstats", qos: .utility)

  private typealias GetTopCoalitions = @convention(c) (UInt64, UInt32, Double) -> Unmanaged<AnyObject>?

  private lazy var getTopCoalitions: GetTopCoalitions? = {
    guard let handle = dlopen("/usr/lib/libsystemstats.dylib", RTLD_NOW | RTLD_LOCAL) else {
      return nil
    }
    guard let symbol = dlsym(handle, "systemstats_get_top_coalitions") else {
      return nil
    }
    return unsafeBitCast(symbol, to: GetTopCoalitions.self)
  }()

  func impact(for bundleIdentifier: String?) -> Double? {
    refreshIfNeeded()
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
    lock.lock()
    let scores = snapshot?.scores
    lock.unlock()
    return scores?[bundleIdentifier]
  }

  private func refreshIfNeeded() {
    let now = Date().timeIntervalSince1970
    lock.lock()
    let shouldFetch = !isFetching && (snapshot == nil || now - lastFetch >= refreshInterval)
    if shouldFetch {
      isFetching = true
    }
    lock.unlock()
    guard shouldFetch else { return }

    fetchQueue.async { [weak self] in
      self?.fetch()
    }
  }

  private func fetch() {
    let fetched = loadSnapshot()
    let now = Date().timeIntervalSince1970
    lock.lock()
    if let fetched {
      snapshot = fetched
    }
    lastFetch = now
    isFetching = false
    lock.unlock()
  }

  private func loadSnapshot() -> Snapshot? {
    guard let getTopCoalitions else { return nil }
    return autoreleasepool {
      guard let dictionary = getTopCoalitions(12 * 60 * 60, 10_000, 0)?.takeUnretainedValue() as? NSDictionary else {
        return nil
      }
      guard let identifiers = dictionary["bundle_identifiers"] as? [Any],
        let impacts = dictionary["energy_impacts"] as? [Any]
      else {
        return nil
      }
      let responsible = dictionary["responsible_bundle_identifiers"] as? [Any] ?? []
      let duration = (dictionary["report_duration"] as? NSNumber)?.doubleValue ?? 0
      guard duration > 0 else { return nil }

      var totals: [String: Double] = [:]
      let count = min(identifiers.count, impacts.count)
      for index in 0..<count {
        let impact = (impacts[index] as? NSNumber)?.doubleValue ?? 0
        let identifier = Self.string(identifiers[index])
        if let identifier {
          totals[identifier, default: 0] += impact
        }
        if index < responsible.count,
          let parent = Self.string(responsible[index]),
          parent != identifier
        {
          totals[parent, default: 0] += impact
        }
      }

      var scores: [String: Double] = [:]
      scores.reserveCapacity(totals.count)
      for (identifier, total) in totals {
        scores[identifier] = total / duration
      }
      return Snapshot(scores: scores)
    }
  }

  private static func string(_ value: Any) -> String? {
    if let value = value as? String, !value.isEmpty {
      return value
    }
    return nil
  }
}
