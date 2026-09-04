internal import Foundation
internal import ScreenCaptureKit
internal import CoreVideo
private import os

private let visuallyCompleteLog = Logger(
  subsystem: "com.remora.app",
  category: "visually-complete"
)

@MainActor
final class VisuallyCompleteTimer {
  private struct PendingMeasurement {
    var startedAt: Date
    let generation: UUID
    var becameInteractiveAt: Date?
    var lastMeaningfulFrameAt: Date?
    var nextCaptureAttemptAt: Date?
  }

  private final class CaptureSession {
    let stream: SCStream
    let output: VisualFrameOutput

    init(stream: SCStream, output: VisualFrameOutput) {
      self.stream = stream
      self.output = output
    }
  }

  private let maximumTrackingDuration: TimeInterval = 60
  private let settledInterval: TimeInterval = 0.75
  private var pending: [pid_t: PendingMeasurement] = [:]
  private var durations: [pid_t: TimeInterval] = [:]
  private var sessions: [pid_t: CaptureSession] = [:]
  private var startTasks: [pid_t: Task<Void, Never>] = [:]

  var isTracking: Bool {
    !pending.isEmpty || !sessions.isEmpty || !startTasks.isEmpty
  }

  func begin(pid: pid_t, startedAt: Date) {
    visuallyCompleteLog.notice("Tracking launch for PID \(pid)")
    stopCapture(for: pid)
    pending[pid] = PendingMeasurement(
      startedAt: startedAt,
      generation: UUID(),
      becameInteractiveAt: nil,
      lastMeaningfulFrameAt: nil,
      nextCaptureAttemptAt: nil
    )
    durations.removeValue(forKey: pid)
  }

  func updateStartDate(_ startedAt: Date, for pid: pid_t) {
    pending[pid]?.startedAt = startedAt
  }

  func becameInteractive(pid: pid_t, at date: Date) {
    guard var measurement = pending[pid], measurement.becameInteractiveAt == nil else { return }
    measurement.becameInteractiveAt = date
    measurement.lastMeaningfulFrameAt = nil
    measurement.nextCaptureAttemptAt = nil
    pending[pid] = measurement
    visuallyCompleteLog.notice("PID \(pid) became interactive; visual settling can begin")
  }

  func refresh(now: Date = Date()) {
    var completed: [(pid: pid_t, duration: TimeInterval)] = []
    var expiredPIDs: [pid_t] = []

    for (pid, measurement) in pending {
      let elapsed = now.timeIntervalSince(measurement.startedAt)
      if elapsed > maximumTrackingDuration {
        expiredPIDs.append(pid)
        continue
      }

      if sessions[pid] == nil,
         startTasks[pid] == nil,
         measurement.becameInteractiveAt != nil,
         measurement.nextCaptureAttemptAt.map({ now >= $0 }) ?? true,
         CGWindowList.primaryWindowFrame(pid: pid) != nil {
        startCapture(for: pid, generation: measurement.generation)
      }

      if let becameInteractiveAt = measurement.becameInteractiveAt,
         let lastFrameAt = measurement.lastMeaningfulFrameAt,
         lastFrameAt >= becameInteractiveAt,
         now.timeIntervalSince(lastFrameAt) >= settledInterval {
        completed.append((pid, max(lastFrameAt.timeIntervalSince(measurement.startedAt), 0)))
      }
    }

    for pid in expiredPIDs {
      pending.removeValue(forKey: pid)
      stopCapture(for: pid)
    }
    for result in completed {
      durations[result.pid] = result.duration
      pending.removeValue(forKey: result.pid)
      stopCapture(for: result.pid)
    }
  }

  func duration(for pid: pid_t) -> TimeInterval? {
    durations[pid]
  }

  func remove(pid: pid_t) {
    pending.removeValue(forKey: pid)
    durations.removeValue(forKey: pid)
    stopCapture(for: pid)
  }

  func stop() {
    for pid in Set(sessions.keys).union(startTasks.keys) {
      stopCapture(for: pid)
    }
    pending.removeAll()
    durations.removeAll()
  }
}

// MARK: - Capture lifecycle

private extension VisuallyCompleteTimer {
  func startCapture(for pid: pid_t, generation: UUID) {
    guard ScreenRecordingPermission.isGranted else {
      visuallyCompleteLog.notice("Screen Recording unavailable for PID \(pid)")
      return
    }

    visuallyCompleteLog.notice("Starting capture lookup for PID \(pid)")
    startTasks[pid] = Task { [weak self] in
      do {
        guard let self,
              let session = try await makeCaptureSession(for: pid, generation: generation)
        else {
          self?.captureStartFinished(for: pid, generation: generation)
          return
        }
        captureDidStart(session, for: pid, generation: generation)
      } catch {
        visuallyCompleteLog.error(
          "Unable to capture PID \(pid): \(error.localizedDescription, privacy: .public)"
        )
        self?.captureStartFinished(for: pid, generation: generation)
      }
    }
  }

  private func makeCaptureSession(
    for pid: pid_t,
    generation: UUID
  ) async throws -> CaptureSession? {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard !Task.isCancelled else { return nil }
    guard let window = Self.captureWindow(for: pid, in: content) else {
      visuallyCompleteLog.notice(
        "No shareable window for PID \(pid); ScreenCaptureKit returned \(content.windows.count) windows"
      )
      return nil
    }
    visuallyCompleteLog.notice(
      "Selected window \(window.windowID) for PID \(pid), size \(window.frame.width)x\(window.frame.height)"
    )

    let output = VisualFrameOutput(pid: pid) { [weak self] frameDate in
      Task { @MainActor in
        self?.receivedMeaningfulFrame(at: frameDate, for: pid, generation: generation)
      }
    } onStop: { [weak self] in
      Task { @MainActor in
        self?.captureDidStop(for: pid, generation: generation)
      }
    }
    let stream = SCStream(
      filter: SCContentFilter(desktopIndependentWindow: window),
      configuration: Self.captureConfiguration(for: window),
      delegate: output
    )
    try stream.addStreamOutput(
      output,
      type: .screen,
      sampleHandlerQueue: VisualFrameOutput.queue
    )
    try await stream.startCapture()
    visuallyCompleteLog.notice("Capture started for PID \(pid), window \(window.windowID)")

    guard !Task.isCancelled else {
      try? await stream.stopCapture()
      return nil
    }
    return CaptureSession(stream: stream, output: output)
  }

  private func captureDidStart(
    _ session: CaptureSession,
    for pid: pid_t,
    generation: UUID
  ) {
    startTasks.removeValue(forKey: pid)
    guard pending[pid]?.generation == generation else {
      Task { try? await session.stream.stopCapture() }
      return
    }
    sessions[pid] = session
  }

  func captureStartFinished(for pid: pid_t, generation: UUID) {
    guard pending[pid]?.generation == generation else { return }
    startTasks.removeValue(forKey: pid)
    pending[pid]?.nextCaptureAttemptAt = Date().addingTimeInterval(0.25)
  }

  func receivedMeaningfulFrame(at date: Date, for pid: pid_t, generation: UUID) {
    guard pending[pid]?.generation == generation else { return }
    pending[pid]?.lastMeaningfulFrameAt = date
  }

  func captureDidStop(for pid: pid_t, generation: UUID) {
    guard pending[pid]?.generation == generation else { return }
    sessions.removeValue(forKey: pid)
    pending[pid]?.lastMeaningfulFrameAt = nil
    pending[pid]?.nextCaptureAttemptAt = Date().addingTimeInterval(0.25)
  }

  func stopCapture(for pid: pid_t) {
    startTasks.removeValue(forKey: pid)?.cancel()
    guard let session = sessions.removeValue(forKey: pid) else { return }
    Task {
      do {
        try await session.stream.stopCapture()
      } catch {
        visuallyCompleteLog.debug(
          "Unable to stop capture for PID \(pid): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  static func captureWindow(for pid: pid_t, in content: SCShareableContent) -> SCWindow? {
    content.windows
      .filter { window in
        window.owningApplication?.processID == pid
          && window.isOnScreen
          && window.frame.width >= CGWindowList.minimumWidth
          && window.frame.height >= CGWindowList.minimumHeight
      }
      .max { lhs, rhs in
        (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
      }
  }

  static func captureConfiguration(for window: SCWindow) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    let scale: CGFloat = 0.5
    configuration.width = max(Int(window.frame.width * scale), 1)
    configuration.height = max(Int(window.frame.height * scale), 1)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 2
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.capturesAudio = false
    return configuration
  }
}
