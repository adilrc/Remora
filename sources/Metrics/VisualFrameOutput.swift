internal import CoreMedia
internal import Foundation
internal import ScreenCaptureKit
internal import CoreVideo
private import os

private let visualFrameLog = Logger(
  subsystem: "com.remora.app",
  category: "visually-complete"
)

final class VisualFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private struct PixelSnapshot {
    var width: Int
    var height: Int
    var samples: [UInt8]
  }

  private struct PixelChangeInfo {
    var changedSampleCount: Int
    var sampleCount: Int

    var isMeaningful: Bool {
      changedSampleCount >= max(8, sampleCount / 1_000)
    }
  }

  static let queue = DispatchQueue(
    label: "com.remora.visually-complete.frames",
    qos: .userInitiated
  )

  private let pid: pid_t
  private let onMeaningfulFrame: @Sendable (Date) -> Void
  private let onStop: @Sendable () -> Void
  private var hasReceivedInitialFrame = false
  private var previousPixelSnapshot: PixelSnapshot?

  init(
    pid: pid_t,
    onMeaningfulFrame: @escaping @Sendable (Date) -> Void,
    onStop: @escaping @Sendable () -> Void
  ) {
    self.pid = pid
    self.onMeaningfulFrame = onMeaningfulFrame
    self.onStop = onStop
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen,
          sampleBuffer.isValid,
          let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
          ) as? [[SCStreamFrameInfo: Any]],
          let attachments = attachmentsArray.first,
          let statusRawValue = attachments[.status] as? Int,
          let status = SCFrameStatus(rawValue: statusRawValue),
          status == .started || status == .complete
    else { return }

    let frameDate = Date()
    let pixelChangeInfo: PixelChangeInfo?
    if let pixelBuffer = sampleBuffer.imageBuffer {
      let result = Self.pixelChangeInfo(pixelBuffer, previous: previousPixelSnapshot)
      previousPixelSnapshot = result.snapshot
      pixelChangeInfo = result.change
    } else {
      pixelChangeInfo = nil
    }
    let isMeaningful = status == .started
      || !hasReceivedInitialFrame
      || pixelChangeInfo?.isMeaningful == true
    if !hasReceivedInitialFrame {
      visualFrameLog.notice(
        "Received first frame for PID \(self.pid), status \(String(describing: status), privacy: .public)"
      )
    }
    hasReceivedInitialFrame = true
    if isMeaningful {
      onMeaningfulFrame(frameDate)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    visualFrameLog.debug(
      "Capture stopped for PID \(self.pid): \(error.localizedDescription, privacy: .public)"
    )
    onStop()
  }
}

// MARK: - Frame inspection

private extension VisualFrameOutput {
  private static func pixelChangeInfo(
    _ pixelBuffer: CVPixelBuffer,
    previous: PixelSnapshot?
  ) -> (snapshot: PixelSnapshot?, change: PixelChangeInfo?) {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
    else { return (nil, nil) }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let samplingStride = 4
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var samples: [UInt8] = []
    samples.reserveCapacity((width / samplingStride) * (height / samplingStride) * 3)
    for row in stride(from: 0, to: height, by: samplingStride) {
      for column in stride(from: 0, to: width, by: samplingStride) {
        let offset = (row * bytesPerRow) + (column * 4)
        samples.append(bytes[offset])
        samples.append(bytes[offset + 1])
        samples.append(bytes[offset + 2])
      }
    }

    let snapshot = PixelSnapshot(width: width, height: height, samples: samples)
    guard let previous,
          previous.width == width,
          previous.height == height,
          previous.samples.count == samples.count
    else { return (snapshot, nil) }

    let channelThreshold = 12
    var changedSampleCount = 0
    for index in stride(from: 0, to: samples.count, by: 3) {
      let blueDifference = abs(Int(samples[index]) - Int(previous.samples[index]))
      let greenDifference = abs(Int(samples[index + 1]) - Int(previous.samples[index + 1]))
      let redDifference = abs(Int(samples[index + 2]) - Int(previous.samples[index + 2]))
      if max(blueDifference, greenDifference, redDifference) >= channelThreshold {
        changedSampleCount += 1
      }
    }
    return (
      snapshot,
      PixelChangeInfo(
        changedSampleCount: changedSampleCount,
        sampleCount: samples.count / 3
      )
    )
  }
}
