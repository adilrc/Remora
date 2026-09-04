import Foundation

struct ProcessMetrics: Sendable, Equatable {
  var cpuPercent: Double?
  var memoryBytes: UInt64?
  var energyImpact: Double?
  var twelveHourEnergyImpact: Double?

  var cpuText: String {
    guard let cpuPercent else { return "—" }
    return String(format: "%.1f%%", cpuPercent)
  }

  var memoryText: String {
    guard let memoryBytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
  }

  var energyImpactText: String {
    guard let energyImpact else { return "—" }
    return String(format: "%.1f", energyImpact)
  }

  var twelveHourText: String {
    guard let twelveHourEnergyImpact else { return "—" }
    return String(format: "%.1f", twelveHourEnergyImpact)
  }
}

@MainActor
final class ProcessMetricsSampler {
  /// Samples are taken every call (twice a second); values are published once per window.
  var refreshInterval: TimeInterval = 5

  private struct Window {
    var startedAt: TimeInterval
    var cpuIntegralNs: UInt64
    var energyScore: Double?
  }

  private struct Published {
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var energyImpact: Double?
  }

  private var previousPIDCPU: [pid_t: UInt64] = [:]
  private var cpuIntegral: [String: UInt64] = [:]
  private var window: [String: Window] = [:]
  private var published: [String: Published] = [:]

  func sample(pid: pid_t, bundleIdentifier: String?, bundlePath: String?) -> ProcessMetrics {
    var related = [pid_t](repeating: 0, count: 512)
    let relatedCount: Int32 = {
      if let bundlePath {
        return bundlePath.withCString { cPath in
          related.withUnsafeMutableBufferPointer { buffer in
            OverlayListRelatedPids(pid, cPath, buffer.baseAddress, Int32(buffer.count))
          }
        }
      }
      return related.withUnsafeMutableBufferPointer { buffer in
        OverlayListRelatedPids(pid, nil, buffer.baseAddress, Int32(buffer.count))
      }
    }()
    let pids = related.prefix(Int(relatedCount)).filter { $0 > 0 }
    guard !pids.isEmpty else {
      return ProcessMetrics()
    }

    let now = Date().timeIntervalSince1970
    var memoryBytes: UInt64 = 0
    var cpuDelta: UInt64 = 0
    var live: Set<pid_t> = []

    for child in pids {
      live.insert(child)
      var raw = OverlayProcessSample()
      guard OverlaySampleProcess(child, &raw) == 0 else { continue }

      let footprint = raw.phys_footprint > 0 ? raw.phys_footprint : raw.resident_bytes
      memoryBytes += footprint

      let cpuTimeNs = raw.cpu_user_ns &+ raw.cpu_system_ns
      if let last = previousPIDCPU[child], cpuTimeNs >= last {
        cpuDelta += cpuTimeNs - last
      }
      previousPIDCPU[child] = cpuTimeNs
    }

    for stale in previousPIDCPU.keys where !live.contains(stale) {
      previousPIDCPU.removeValue(forKey: stale)
    }

    let key = bundleIdentifier ?? "pid:\(pid)"
    let integral = (cpuIntegral[key] ?? 0) &+ cpuDelta
    cpuIntegral[key] = integral
    var energyScore: Double?
    var cumulativeEnergy = 0.0
    if OverlaySampleEnergyImpact(pid, &cumulativeEnergy) == 0 {
      energyScore = cumulativeEnergy
    }

    publishIfWindowElapsed(key: key, now: now, cpuIntegralNs: integral, memoryBytes: memoryBytes, energyScore: energyScore)

    let current = published[key] ?? Published()
    return ProcessMetrics(
      cpuPercent: current.cpuPercent,
      memoryBytes: current.memoryBytes,
      energyImpact: current.energyImpact,
      twelveHourEnergyImpact: SystemStatsEnergyStore.shared.impact(for: bundleIdentifier)
    )
  }
}

// MARK: - Private functionality

private extension ProcessMetricsSampler {
  func publishIfWindowElapsed(
    key: String,
    now: TimeInterval,
    cpuIntegralNs: UInt64,
    memoryBytes: UInt64,
    energyScore: Double?
  ) {
    guard let window = window[key] else {
      // First sight of this app: show memory right away, rates need a full window.
      self.window[key] = Window(startedAt: now, cpuIntegralNs: cpuIntegralNs, energyScore: energyScore)
      published[key] = Published(cpuPercent: nil, memoryBytes: memoryBytes, energyImpact: nil)
      return
    }

    let elapsed = now - window.startedAt
    // The sampling tick is not phase-locked to the window, so accept a slightly short window.
    guard elapsed >= refreshInterval - 0.3 else { return }

    var next = published[key] ?? Published()
    next.memoryBytes = memoryBytes
    if elapsed <= refreshInterval * 2 + 2 {
      // A window far longer than expected means the Mac slept; skip the rates for it.
      if cpuIntegralNs >= window.cpuIntegralNs {
        next.cpuPercent = max(Double(cpuIntegralNs - window.cpuIntegralNs) / (elapsed * 1_000_000_000.0) * 100.0, 0)
      }
      if let energyScore, let start = window.energyScore, energyScore >= start {
        next.energyImpact = max((energyScore - start) / elapsed, 0)
      }
    }
    published[key] = next
    self.window[key] = Window(startedAt: now, cpuIntegralNs: cpuIntegralNs, energyScore: energyScore)
  }
}
