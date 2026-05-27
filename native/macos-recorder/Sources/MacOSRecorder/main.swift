import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: Error, LocalizedError {
  case invalidArguments(String)
  case missingSource(String)
  case recordingUnavailable(String)
  case writerFailure(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message),
         .missingSource(let message),
         .recordingUnavailable(let message),
         .writerFailure(let message):
      return message
    }
  }
}

enum MixedAudioSourceKind: String {
  case system
  case microphone
}

struct NativeCaptureSource: Codable {
  let id: String
  let kind: String
  let name: String
  let owningApplication: String?
  let x: Int?
  let y: Int?
  let width: Int?
  let height: Int?
}

struct SourceListResponse: Codable {
  let sources: [NativeCaptureSource]
}

struct EventMessage: Codable {
  let type: String
  let message: String?
  let audioSummary: String?
  let sourceName: String?
}

struct RecordingOptions {
  let sourceId: String
  let outputDirectory: URL
  let videoPath: URL
  let audioPath: URL
  let captureMicrophone: Bool
  let debugCaptureOnly: Bool
  let cropRect: CGRect?
}

struct OfflineMixSource {
  let kind: MixedAudioSourceKind
  let buffer: AVAudioPCMBuffer
  let startFrame: Int64
}

@MainActor
struct MacOSRecorderCLI {
  static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
      throw RecorderError.invalidArguments("Expected a command: list-sources or record")
    }

    switch command {
    case "list-sources":
      let sources = try await listSources()
      let response = SourceListResponse(sources: sources)
      let data = try JSONEncoder().encode(response)
      FileHandle.standardOutput.write(data)
    case "record":
      let options = try parseOptions(from: Array(arguments.dropFirst()))
      if options.debugCaptureOnly {
        let recorder = try await DebugNativeCaptureSession(options: options)
        try await recorder.recordUntilInterrupted()
      } else {
        let recorder = try await NativeRecordingSession(options: options)
        try await recorder.recordUntilInterrupted()
      }
    default:
      throw RecorderError.invalidArguments("Unknown command: \(command)")
    }
  }

  private static func listSources() async throws -> [NativeCaptureSource] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    let displays = content.displays.map { display in
      NativeCaptureSource(
        id: "display:\(display.displayID)",
        kind: "display",
        name: "Display \(display.displayID)",
        owningApplication: nil,
        x: Int(display.frame.origin.x),
        y: Int(display.frame.origin.y),
        width: Int(display.width),
        height: Int(display.height)
      )
    }

    let windows = content.windows
      .filter { $0.isOnScreen }
      .map { window in
        NativeCaptureSource(
          id: "window:\(window.windowID)",
          kind: "window",
          name: window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Untitled Window"),
          owningApplication: window.owningApplication?.applicationName,
          x: Int(window.frame.origin.x),
          y: Int(window.frame.origin.y),
          width: Int(window.frame.width),
          height: Int(window.frame.height)
        )
      }

    return windows + displays
  }

  private static func parseOptions(from arguments: [String]) throws -> RecordingOptions {
    var values: [String: String] = [:]
    var index = 0

    while index < arguments.count {
      let key = arguments[index]
      let nextIndex = index + 1

      guard key.hasPrefix("--"), nextIndex < arguments.count else {
        throw RecorderError.invalidArguments("Invalid argument list")
      }

      values[String(key.dropFirst(2))] = arguments[nextIndex]
      index += 2
    }

    guard
      let sourceId = values["source-id"],
      let outputDirectory = values["output-dir"],
      let videoPath = values["video-path"],
      let audioPath = values["audio-path"]
    else {
      throw RecorderError.invalidArguments("Missing required record arguments")
    }

    let cropRect: CGRect?
    if
      let cropX = values["crop-x"].flatMap(Double.init),
      let cropY = values["crop-y"].flatMap(Double.init),
      let cropWidth = values["crop-width"].flatMap(Double.init),
      let cropHeight = values["crop-height"].flatMap(Double.init)
    {
      cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
    } else {
      cropRect = nil
    }

    return RecordingOptions(
      sourceId: sourceId,
      outputDirectory: URL(fileURLWithPath: outputDirectory),
      videoPath: URL(fileURLWithPath: videoPath),
      audioPath: URL(fileURLWithPath: audioPath),
      captureMicrophone: values["capture-microphone"] == "true",
      debugCaptureOnly: values["debug-capture-only"] == "true",
      cropRect: cropRect
    )
  }

  nonisolated static func emitEvent(type: String, message: String?, audioSummary: String?, sourceName: String?) {
    let event = EventMessage(type: type, message: message, audioSummary: audioSummary, sourceName: sourceName)

    guard let data = try? JSONEncoder().encode(event), let line = String(data: data, encoding: .utf8) else {
      return
    }

    print(line)
    fflush(stdout)
  }
}

enum CaptureSourceReference {
  case display(SCDisplay)
  case window(SCWindow)

  var displayName: String {
    switch self {
    case .display(let display):
      return "Display \(display.displayID)"
    case .window(let window):
      return window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Untitled Window")
    }
  }

  var width: Int {
    switch self {
    case .display(let display):
      return Int(display.width)
    case .window(let window):
      return Int(window.frame.width)
    }
  }

  var height: Int {
    switch self {
    case .display(let display):
      return Int(display.height)
    case .window(let window):
      return Int(window.frame.height)
    }
  }

  var originX: Int {
    switch self {
    case .display(let display):
      return Int(display.frame.origin.x)
    case .window(let window):
      return Int(window.frame.origin.x)
    }
  }

  var originY: Int {
    switch self {
    case .display(let display):
      return Int(display.frame.origin.y)
    case .window(let window):
      return Int(window.frame.origin.y)
    }
  }
}

final class SignalRelay {
  static let shared = SignalRelay()
  private var handler: (() -> Void)?

  func install(handler: @escaping () -> Void) {
    self.handler = handler
    signal(SIGINT) { _ in
      SignalRelay.shared.handler?()
    }
    signal(SIGTERM) { _ in
      SignalRelay.shared.handler?()
    }
  }
}

@preconcurrency
final class DebugNativeCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
  private let options: RecordingOptions
  private let source: CaptureSourceReference
  private var stream: SCStream!
  private let videoQueue = DispatchQueue(label: "botless-notetaker.debug-recorder.video", qos: .userInitiated)
  private let didEmitStartedEvent = LockedState(false)
  private let videoSamplesReceived = LockedState(0)
  private let completeVideoFramesReceived = LockedState(0)
  private let lastVideoSampleTime = LockedState<CMTime?>(nil)
  private let lastProgressLogTime = LockedState<CFAbsoluteTime>(0)
  private let completionHandler = LockedState<((Result<Void, Error>) -> Void)?>(nil)
  private let finishing = LockedState(false)

  init(options: RecordingOptions) async throws {
    self.options = options
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    self.source = try Self.resolveSource(sourceId: options.sourceId, content: content)
    super.init()

    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = false
    configuration.captureMicrophone = false
    configuration.excludesCurrentProcessAudio = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 6
    configuration.width = Self.sanitizeVideoDimension(source.width)
    configuration.height = Self.sanitizeVideoDimension(source.height)

    let filter = try Self.makeContentFilter(for: source)
    self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
  }

  func recordUntilInterrupted() async throws {
    try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
      completionHandler.withLock { handler in
        handler = { result in
          switch result {
          case .success:
            continuation.resume()
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      }

      SignalRelay.shared.install {
        Task {
          do {
            try await self.stop()
            self.resolveCompletion(.success(()))
          } catch {
            self.resolveCompletion(.failure(error))
          }
        }
      }

      Task { @MainActor in
        do {
          MacOSRecorderCLI.emitEvent(type: "debug", message: "Prepared native source \(self.source.displayName) origin=\(self.source.originX),\(self.source.originY) size=\(self.source.width)x\(self.source.height) crop=nil outputDir=\(self.options.outputDirectory.path)", audioSummary: nil, sourceName: self.source.displayName)
          MacOSRecorderCLI.emitEvent(type: "debug", message: "Starting SCStream capture", audioSummary: nil, sourceName: self.source.displayName)
          try await self.stream.startCapture()
          MacOSRecorderCLI.emitEvent(type: "debug", message: "SCStream capture started", audioSummary: nil, sourceName: self.source.displayName)
          self.emitStartedEventIfNeeded()
        } catch {
          self.resolveCompletion(.failure(error))
        }
      }
    }
  }

  nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard CMSampleBufferIsValid(sampleBuffer), outputType == .screen else {
      return
    }

    videoSamplesReceived.withLock { $0 += 1 }
    lastVideoSampleTime.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }

    if let status = Self.frameStatus(for: sampleBuffer), status == .complete {
      completeVideoFramesReceived.withLock { $0 += 1 }
    }

    emitProgressDebugIfNeeded()
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    MacOSRecorderCLI.emitEvent(
      type: "error",
      message: "SCStream stopped with error: \(error.localizedDescription)",
      audioSummary: nil,
      sourceName: source.displayName
    )

    resolveCompletion(.failure(error))
  }

  private func stop() async throws {
    if finishing.withLock({ state in
      if state { return true }
      state = true
      return false
    }) {
      return
    }

    do {
      try await stream.stopCapture()
    } catch {
      let message = error.localizedDescription
      if !message.contains("already stopped") && !message.contains("does not exist") {
        throw error
      }
    }

    MacOSRecorderCLI.emitEvent(type: "debug", message: debugSummary(), audioSummary: nil, sourceName: source.displayName)
    MacOSRecorderCLI.emitEvent(type: "recording-stopped", message: nil, audioSummary: nil, sourceName: nil)
  }

  private func emitStartedEventIfNeeded() {
    let shouldEmit = didEmitStartedEvent.withLock { state -> Bool in
      if state {
        return false
      }
      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "recording-started",
      message: nil,
      audioSummary: "debug capture-only mode | no media files are written | video stream only",
      sourceName: source.displayName
    )
  }

  private func emitProgressDebugIfNeeded() {
    let now = CFAbsoluteTimeGetCurrent()
    let shouldEmit = lastProgressLogTime.withLock { lastTime -> Bool in
      if now - lastTime < 5 {
        return false
      }
      lastTime = now
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(type: "debug", message: "Capture progress (video): \(debugSummary())", audioSummary: nil, sourceName: source.displayName)
  }

  private func debugSummary() -> String {
    let videoSamples = videoSamplesReceived.withLock { $0 }
    let completeFrames = completeVideoFramesReceived.withLock { $0 }
    let lastVideo = lastVideoSampleTime.withLock { $0 }

    return [
      "videoSamples=\(videoSamples)",
      "completeVideoFrames=\(completeFrames)",
      "lastVideoPTS=\(Self.describeTime(lastVideo))"
    ].joined(separator: " | ")
  }

  private static func resolveSource(sourceId: String, content: SCShareableContent) throws -> CaptureSourceReference {
    if sourceId.hasPrefix("display:"), let id = UInt32(sourceId.replacingOccurrences(of: "display:", with: "")) {
      guard let display = content.displays.first(where: { $0.displayID == id }) else {
        throw RecorderError.missingSource("Display source not found: \(sourceId)")
      }
      return .display(display)
    }

    if sourceId.hasPrefix("window:"), let id = UInt32(sourceId.replacingOccurrences(of: "window:", with: "")) {
      guard let window = content.windows.first(where: { $0.windowID == id }) else {
        throw RecorderError.missingSource("Window source not found: \(sourceId)")
      }
      return .window(window)
    }

    throw RecorderError.invalidArguments("Unknown source id: \(sourceId)")
  }

  private static func makeContentFilter(for source: CaptureSourceReference) throws -> SCContentFilter {
    switch source {
    case .display(let display):
      return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    case .window(let window):
      return SCContentFilter(desktopIndependentWindow: window)
    }
  }

  private static func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let attachments = attachmentsArray.first,
      let statusRawValue = attachments[.status] as? Int
    else {
      return nil
    }

    return SCFrameStatus(rawValue: statusRawValue)
  }

  private static func sanitizeVideoDimension(_ value: Int) -> Int {
    let normalized = max(value, 2)
    return normalized.isMultiple(of: 2) ? normalized : normalized - 1
  }

  private static func describeTime(_ time: CMTime?) -> String {
    guard let time else {
      return "nil"
    }

    guard time.isNumeric else {
      return "non-numeric"
    }

    return String(format: "%.3fs", time.seconds)
  }

  private func resolveCompletion(_ result: Result<Void, Error>) {
    let handler = completionHandler.withLock { handler -> ((Result<Void, Error>) -> Void)? in
      let current = handler
      handler = nil
      return current
    }

    handler?(result)
  }
}

@preconcurrency
final class NativeRecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
  private let options: RecordingOptions
  private let source: CaptureSourceReference
  private var stream: SCStream!
  private let videoSampleQueue = DispatchQueue(label: "botless-notetaker.native-recorder.video-samples", qos: .userInitiated)
  private let systemAudioSampleQueue = DispatchQueue(label: "botless-notetaker.native-recorder.system-audio-samples", qos: .userInitiated)
  private let microphoneSampleQueue = DispatchQueue(label: "botless-notetaker.native-recorder.microphone-samples", qos: .userInitiated)
  private let videoWriter: AVAssetWriter?
  private let rawAudioPath: URL
  private let systemAudioPath: URL
  private let microphoneAudioPath: URL
  private var videoInput: AVAssetWriterInput?
  private var systemAudioFile: AVAudioFile?
  private var microphoneAudioFile: AVAudioFile?
  private var systemAudioStartTime: CMTime?
  private var microphoneAudioStartTime: CMTime?
  private let startedAt = LockedState<CMTime?>(nil)
  private let finishing = LockedState(false)
  private let didEmitStartedEvent = LockedState(false)
  private let sawFirstVideoSample = LockedState(false)
  private let sawFirstAudioSample = LockedState(false)
  private let sawFirstMicrophoneSample = LockedState(false)
  private let loggedAudioFormat = LockedState(false)
  private let loggedMicrophoneFormat = LockedState(false)
  private let loggedVideoFormat = LockedState(false)
  private let appendedFirstVideoFrame = LockedState(false)
  private let loggedSkippedVideoStatus = LockedState<SCFrameStatus?>(nil)
  private let lastAudioLevelLogTime = LockedState<CFAbsoluteTime>(0)
  private let lastMicrophoneLevelLogTime = LockedState<CFAbsoluteTime>(0)
  private let lastProgressLogTime = LockedState<CFAbsoluteTime>(0)
  private let videoSamplesReceived = LockedState(0)
  private let completeVideoFramesReceived = LockedState(0)
  private let videoFramesAppended = LockedState(0)
  private let videoFramesDroppedNotReady = LockedState(0)
  private let systemAudioBuffersWritten = LockedState(0)
  private let microphoneAudioBuffersWritten = LockedState(0)
  private let lastVideoSampleTime = LockedState<CMTime?>(nil)
  private let lastCompleteVideoSampleTime = LockedState<CMTime?>(nil)
  private let lastSystemAudioSampleTime = LockedState<CMTime?>(nil)
  private let lastMicrophoneAudioSampleTime = LockedState<CMTime?>(nil)
  private let completionHandler = LockedState<((Result<Void, Error>) -> Void)?>(nil)

  init(options: RecordingOptions) async throws {
    self.options = options
    self.rawAudioPath = options.outputDirectory.appendingPathComponent("audio-raw.caf")
    self.systemAudioPath = options.outputDirectory.appendingPathComponent("system-audio.caf")
    self.microphoneAudioPath = options.outputDirectory.appendingPathComponent("microphone-audio.caf")
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    self.source = try Self.resolveSource(sourceId: options.sourceId, content: content)
    self.videoWriter = options.debugCaptureOnly
      ? nil
      : try AVAssetWriter(outputURL: options.videoPath, fileType: .mov)

    super.init()

    let configuration = Self.makeStreamConfiguration(for: self.source, cropRect: options.cropRect, debugCaptureOnly: options.debugCaptureOnly)
    let filter = try Self.makeContentFilter(for: self.source)
    self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)

    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Prepared native source \(self.source.displayName) origin=\(self.source.originX),\(self.source.originY) size=\(self.source.width)x\(self.source.height) crop=\(Self.describeRect(options.cropRect)) outputDir=\(options.outputDirectory.path)",
      audioSummary: nil,
      sourceName: self.source.displayName
    )

    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
    if !options.debugCaptureOnly {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioSampleQueue)
    }
    if options.captureMicrophone && !options.debugCaptureOnly {
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneSampleQueue)
    }

  }

  func recordUntilInterrupted() async throws {
    try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
      completionHandler.withLock { handler in
        handler = { result in
          switch result {
          case .success:
            continuation.resume()
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      }

      SignalRelay.shared.install {
        Task {
          do {
            try await self.stop()
            self.resolveRecordingCompletion(.success(()))
          } catch {
            self.resolveRecordingCompletion(.failure(error))
          }
        }
      }

      Task { @MainActor in
        do {
          MacOSRecorderCLI.emitEvent(type: "debug", message: "Starting SCStream capture", audioSummary: nil, sourceName: self.source.displayName)
          try await self.stream.startCapture()
          MacOSRecorderCLI.emitEvent(type: "debug", message: "SCStream capture started", audioSummary: nil, sourceName: self.source.displayName)
          if self.options.debugCaptureOnly {
            self.emitStartedEventIfNeeded()
          }
        } catch {
          self.resolveRecordingCompletion(.failure(error))
        }
      }
    }
  }

  nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard CMSampleBufferIsValid(sampleBuffer) else {
      return
    }

    switch outputType {
    case .screen:
      emitFirstSampleEventIfNeeded(type: "video")
      appendVideo(sampleBuffer)
    case .audio:
      emitFirstSampleEventIfNeeded(type: "audio")
      appendAudio(sampleBuffer, source: .system)
    case .microphone:
      emitFirstSampleEventIfNeeded(type: "microphone")
      appendAudio(sampleBuffer, source: .microphone)
    default:
      break
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    MacOSRecorderCLI.emitEvent(
      type: "error",
      message: "SCStream stopped with error: \(error.localizedDescription)",
      audioSummary: nil,
      sourceName: source.displayName
    )

    Task { @MainActor in
      do {
        try await self.stop()
        self.resolveRecordingCompletion(.failure(error))
      } catch {
        MacOSRecorderCLI.emitEvent(
          type: "error",
          message: "Failed to finalize after SCStream interruption: \(error.localizedDescription)",
          audioSummary: nil,
          sourceName: self.source.displayName
        )
        self.resolveRecordingCompletion(.failure(error))
      }
    }
  }

  private func stop() async throws {
    if finishing.withLock({ state in
      if state { return true }
      state = true
      return false
    }) {
      return
    }

    do {
      try await stream.stopCapture()
    } catch {
      let message = error.localizedDescription

      if message.contains("already stopped") || message.contains("does not exist") {
        MacOSRecorderCLI.emitEvent(type: "debug", message: "Ignoring duplicate stream stop request", audioSummary: nil, sourceName: source.displayName)
      } else {
        throw error
      }
    }

    if options.debugCaptureOnly {
      MacOSRecorderCLI.emitEvent(type: "debug", message: recordingSummary(), audioSummary: nil, sourceName: source.displayName)
      MacOSRecorderCLI.emitEvent(type: "recording-stopped", message: nil, audioSummary: nil, sourceName: nil)
      return
    }

    guard let videoWriter else {
      throw RecorderError.writerFailure("Video writer missing in recording mode")
    }

    videoInput?.markAsFinished()

    if videoWriter.status == .unknown {
      throw RecorderError.writerFailure("Native recorder stopped before any valid media samples were written")
    }

    if videoWriter.status == .failed {
      throw RecorderError.writerFailure("Video writer failed before finish: \(writerErrorDescription(videoWriter))")
    }

    if videoWriter.status == .writing {
      MacOSRecorderCLI.emitEvent(type: "debug", message: "Finishing video writer from status=writing", audioSummary: nil, sourceName: source.displayName)
      await finishWriting(videoWriter)
    }

    if videoWriter.status == .failed {
      throw RecorderError.writerFailure("Video writer failed while finishing: \(writerErrorDescription(videoWriter))")
    }

    try await exportAudioFileIfNeeded()

    MacOSRecorderCLI.emitEvent(type: "debug", message: recordingSummary(), audioSummary: nil, sourceName: source.displayName)
    MacOSRecorderCLI.emitEvent(type: "debug", message: outputFileSummary(), audioSummary: nil, sourceName: source.displayName)
    MacOSRecorderCLI.emitEvent(type: "debug", message: "Video writer finished with status=\(videoWriter.status.rawValue)", audioSummary: nil, sourceName: source.displayName)
    MacOSRecorderCLI.emitEvent(type: "debug", message: "Audio file finalized", audioSummary: nil, sourceName: source.displayName)
    MacOSRecorderCLI.emitEvent(type: "recording-stopped", message: nil, audioSummary: nil, sourceName: nil)
  }

  private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    videoSamplesReceived.withLock { $0 += 1 }
    lastVideoSampleTime.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    emitProgressDebugIfNeeded(trigger: "video")

    guard let frameStatus = Self.frameStatus(for: sampleBuffer) else {
      return
    }

    guard frameStatus == .complete else {
      emitSkippedVideoStatusDebugIfNeeded(frameStatus)
      return
    }

    completeVideoFramesReceived.withLock { $0 += 1 }
    lastCompleteVideoSampleTime.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }

    if options.debugCaptureOnly {
      return
    }

    guard let videoWriter else {
      MacOSRecorderCLI.emitEvent(type: "error", message: "Video writer missing in recording mode", audioSummary: nil, sourceName: source.displayName)
      return
    }

    do {
      try ensureVideoInput(using: sampleBuffer)
      try startVideoWriterIfNeeded(using: sampleBuffer)
    } catch {
      MacOSRecorderCLI.emitEvent(type: "error", message: error.localizedDescription, audioSummary: nil, sourceName: source.displayName)
      return
    }

    guard let videoInput, videoWriter.status == .writing, videoInput.isReadyForMoreMediaData else {
      videoFramesDroppedNotReady.withLock { $0 += 1 }
      return
    }

    if !videoInput.append(sampleBuffer) {
      MacOSRecorderCLI.emitEvent(
        type: "error",
        message: "Video append failed: \(writerErrorDescription(videoWriter))",
        audioSummary: nil,
        sourceName: source.displayName
      )
      return
    }

    videoFramesAppended.withLock { $0 += 1 }
    emitFirstVideoAppendDebugIfNeeded()
  }

  private func appendAudio(_ sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) {
    switch source {
    case .system:
      lastSystemAudioSampleTime.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    case .microphone:
      lastMicrophoneAudioSampleTime.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    }
    emitProgressDebugIfNeeded(trigger: source.rawValue)
    emitAudioFormatDebugIfNeeded(for: sampleBuffer, source: source)
    emitAudioLevelDebugIfNeeded(for: sampleBuffer, source: source)

    if options.debugCaptureOnly {
      switch source {
      case .system:
        systemAudioBuffersWritten.withLock { $0 += 1 }
      case .microphone:
        microphoneAudioBuffersWritten.withLock { $0 += 1 }
      }
      return
    }

    do {
      try appendAudioSample(toFile: sampleBuffer, source: source)
    } catch {
      MacOSRecorderCLI.emitEvent(type: "error", message: error.localizedDescription, audioSummary: nil, sourceName: self.source.displayName)
    }
  }

  private func startVideoWriterIfNeeded(using sampleBuffer: CMSampleBuffer) throws {
    guard let videoWriter else {
      throw RecorderError.writerFailure("Video writer unavailable in debug capture-only mode")
    }

    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    let didStart = startedAt.withLock { state -> Bool in
      if state != nil {
        return false
      }

      state = presentationTime
      return true
    }

    guard didStart else {
      return
    }

    videoWriter.startWriting()

    guard videoWriter.status == .writing else {
      throw RecorderError.writerFailure("Video writer failed to startWriting: \(writerErrorDescription(videoWriter))")
    }

    videoWriter.startSession(atSourceTime: presentationTime)
    MacOSRecorderCLI.emitEvent(type: "debug", message: "Video writer started at \(presentationTime.seconds)s", audioSummary: nil, sourceName: source.displayName)
    emitStartedEventIfNeeded()
  }

  private func finishWriting(_ writer: AVAssetWriter) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }
  }

  private static func resolveSource(sourceId: String, content: SCShareableContent) throws -> CaptureSourceReference {
    if sourceId.hasPrefix("display:"), let id = UInt32(sourceId.replacingOccurrences(of: "display:", with: "")) {
      guard let display = content.displays.first(where: { $0.displayID == id }) else {
        throw RecorderError.missingSource("Display source not found: \(sourceId)")
      }

      return .display(display)
    }

    if sourceId.hasPrefix("window:"), let id = UInt32(sourceId.replacingOccurrences(of: "window:", with: "")) {
      guard let window = content.windows.first(where: { $0.windowID == id }) else {
        throw RecorderError.missingSource("Window source not found: \(sourceId)")
      }

      return .window(window)
    }

    throw RecorderError.invalidArguments("Unknown source id: \(sourceId)")
  }

  private static func makeContentFilter(for source: CaptureSourceReference) throws -> SCContentFilter {
    switch source {
    case .display(let display):
      return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    case .window(let window):
      return SCContentFilter(desktopIndependentWindow: window)
    }
  }

  private static func makeStreamConfiguration(for source: CaptureSourceReference, cropRect: CGRect?, debugCaptureOnly: Bool) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = !debugCaptureOnly
    configuration.captureMicrophone = !debugCaptureOnly
    configuration.excludesCurrentProcessAudio = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 6
    let targetWidth = cropRect.map { Int($0.width) } ?? source.width
    let targetHeight = cropRect.map { Int($0.height) } ?? source.height
    configuration.width = sanitizeVideoDimension(targetWidth)
    configuration.height = sanitizeVideoDimension(targetHeight)
    if let cropRect {
      configuration.sourceRect = cropRect
    }
    return configuration
  }

  private static func makeVideoInput(width: Int, height: Int, formatHint: CMFormatDescription?) -> AVAssetWriterInput {
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: max(width * height * 6, 8_000_000),
        AVVideoMaxKeyFrameIntervalKey: 30
      ]
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: formatHint)
    input.expectsMediaDataInRealTime = true
    return input
  }

  private static func audioSummary(captureMicrophone: Bool) -> String {
    let micSummary = captureMicrophone
      ? "system audio and microphone are being captured and exported to audio.m4a"
      : "microphone disabled"
    return "video.mov and audio.m4a are being written natively | \(micSummary)"
  }

  private static func debugAudioSummary(captureMicrophone: Bool) -> String {
    let micSummary = captureMicrophone
      ? "system audio and microphone are being captured"
      : "microphone disabled"
    return "debug capture-only mode | no media files are written | \(micSummary)"
  }

  private func emitStartedEventIfNeeded() {
    let shouldEmit = didEmitStartedEvent.withLock { state -> Bool in
      if state {
        return false
      }

      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "recording-started",
      message: nil,
      audioSummary: options.debugCaptureOnly
        ? Self.debugAudioSummary(captureMicrophone: options.captureMicrophone)
        : Self.audioSummary(captureMicrophone: options.captureMicrophone),
      sourceName: source.displayName
    )
  }

  private func emitFirstSampleEventIfNeeded(type: String) {
    let tracker: LockedState<Bool>
    switch type {
    case "video":
      tracker = sawFirstVideoSample
    case "audio":
      tracker = sawFirstAudioSample
    case "microphone":
      tracker = sawFirstMicrophoneSample
    default:
      tracker = sawFirstAudioSample
    }
    let shouldEmit = tracker.withLock { state -> Bool in
      if state {
        return false
      }

      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Received first \(type) sample",
      audioSummary: nil,
      sourceName: source.displayName
    )
  }

  private func ensureVideoInput(using sampleBuffer: CMSampleBuffer) throws {
    if videoInput != nil {
      return
    }

    guard let videoWriter else {
      throw RecorderError.writerFailure("Video writer unavailable in debug capture-only mode")
    }

    let dimensions = Self.videoDimensions(from: sampleBuffer, fallbackWidth: source.width, fallbackHeight: source.height)
    emitVideoFormatDebugIfNeeded(for: sampleBuffer, dimensions: dimensions)

    let input = Self.makeVideoInput(
      width: dimensions.width,
      height: dimensions.height,
      formatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
    )

    guard videoWriter.canAdd(input) else {
      throw RecorderError.writerFailure("Unable to add video input to AVAssetWriter")
    }

    videoWriter.add(input)
    videoInput = input
  }

  private func writerErrorDescription(_ writer: AVAssetWriter) -> String {
    guard let error = writer.error else {
      return "unknown writer error"
    }

    let nsError = error as NSError
    var parts = [
      error.localizedDescription,
      "domain=\(nsError.domain)",
      "code=\(nsError.code)"
    ]

    if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
      parts.append("reason=\(failureReason)")
    }

    if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
      parts.append("suggestion=\(recoverySuggestion)")
    }

    if nsError.userInfo.isEmpty == false {
      parts.append("userInfo=\(nsError.userInfo)")
    }

    return parts.joined(separator: " | ")
  }

  private func ensureAudioFile(for source: MixedAudioSourceKind, format: AVAudioFormat) throws -> AVAudioFile {
    switch source {
    case .system:
      if systemAudioFile == nil {
        systemAudioFile = try AVAudioFile(
          forWriting: systemAudioPath,
          settings: format.settings,
          commonFormat: format.commonFormat,
          interleaved: format.isInterleaved
        )
      }

      guard let systemAudioFile else {
        throw RecorderError.writerFailure("Unable to create system audio file")
      }

      return systemAudioFile
    case .microphone:
      if microphoneAudioFile == nil {
        microphoneAudioFile = try AVAudioFile(
          forWriting: microphoneAudioPath,
          settings: format.settings,
          commonFormat: format.commonFormat,
          interleaved: format.isInterleaved
        )
      }

      guard let microphoneAudioFile else {
        throw RecorderError.writerFailure("Unable to create microphone audio file")
      }

      return microphoneAudioFile
    }
  }

  private func appendAudioSample(toFile sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) throws {
    let (audioFile, pcmBuffer) = try ensureAudioFileAndBuffer(from: sampleBuffer, source: source)
    try audioFile.write(from: pcmBuffer)
    switch source {
    case .system:
      systemAudioBuffersWritten.withLock { $0 += 1 }
    case .microphone:
      microphoneAudioBuffersWritten.withLock { $0 += 1 }
    }
  }

  private func ensureAudioFileAndBuffer(from sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) throws -> (AVAudioFile, AVAudioPCMBuffer) {
    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
      let audioFormat = AVAudioFormat(streamDescription: streamDescription)
    else {
      throw RecorderError.writerFailure("Unable to inspect \(source.rawValue) audio sample format for AVAudioFile")
    }

    let file = try ensureAudioFile(for: source, format: audioFormat)
    let pcmBuffer = try Self.makePCMBuffer(from: sampleBuffer, audioFormat: audioFormat)

    if source == .system && systemAudioStartTime == nil {
      systemAudioStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      MacOSRecorderCLI.emitEvent(type: "debug", message: "Audio file started at \(presentationTime.seconds)s", audioSummary: nil, sourceName: self.source.displayName)
    }

    if source == .microphone && microphoneAudioStartTime == nil {
      microphoneAudioStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    return (file, pcmBuffer)
  }

  private func emitAudioLevelDebugIfNeeded(for sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) {
    let tracker = source == .system ? lastAudioLevelLogTime : lastMicrophoneLevelLogTime
    let now = CFAbsoluteTimeGetCurrent()
    let shouldEmit = tracker.withLock { lastTime -> Bool in
      if now - lastTime < 2 {
        return false
      }

      lastTime = now
      return true
    }

    guard shouldEmit else {
      return
    }

    let description = Self.describeAudioLevel(sampleBuffer)
    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "\(source.rawValue.capitalized) audio level: \(description)",
      audioSummary: nil,
      sourceName: self.source.displayName
    )
  }

  private func emitAudioFormatDebugIfNeeded(for sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) {
    let tracker = source == .system ? loggedAudioFormat : loggedMicrophoneFormat
    let shouldEmit = tracker.withLock { state -> Bool in
      if state {
        return false
      }

      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    let description = Self.describeAudioSampleFormat(sampleBuffer)
    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "\(source.rawValue.capitalized) audio sample format: \(description)",
      audioSummary: nil,
      sourceName: self.source.displayName
    )
  }

  private func exportAudioFileIfNeeded() async throws {
    let hasSystemAudio = FileManager.default.fileExists(atPath: systemAudioPath.path)
    let hasMicrophoneAudio = FileManager.default.fileExists(atPath: microphoneAudioPath.path)

    guard hasSystemAudio || hasMicrophoneAudio else {
      return
    }

    let mixedUrl = try mixAudioFilesOffline(hasSystemAudio: hasSystemAudio, hasMicrophoneAudio: hasMicrophoneAudio)

    if FileManager.default.fileExists(atPath: options.audioPath.path) {
      try? FileManager.default.removeItem(at: options.audioPath)
    }

    let asset = AVURLAsset(url: mixedUrl)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw RecorderError.recordingUnavailable("Unable to create audio export session")
    }

    exportSession.outputURL = options.audioPath
    exportSession.outputFileType = .m4a

    do {
      try await exportSession.export(to: options.audioPath, as: .m4a)
    } catch {
      throw RecorderError.recordingUnavailable("Audio export failed: \(error.localizedDescription)")
    }

    cleanupIntermediateAudioFiles()
  }

  private func cleanupIntermediateAudioFiles() {
    let paths = [rawAudioPath, systemAudioPath, microphoneAudioPath]

    for path in paths where FileManager.default.fileExists(atPath: path.path) {
      try? FileManager.default.removeItem(at: path)
    }
  }

  private func emitVideoFormatDebugIfNeeded(for sampleBuffer: CMSampleBuffer, dimensions: (width: Int, height: Int)) {
    let shouldEmit = loggedVideoFormat.withLock { state -> Bool in
      if state {
        return false
      }

      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    let description = Self.describeVideoSampleFormat(sampleBuffer, dimensions: dimensions)
    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Video sample format: \(description)",
      audioSummary: nil,
      sourceName: source.displayName
    )
  }

  private static func describeAudioSampleFormat(_ sampleBuffer: CMSampleBuffer) -> String {
    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return "unavailable"
    }

    let value = streamDescription.pointee
    let flags = String(value.mFormatFlags, radix: 16)

    return [
      "sampleRate=\(value.mSampleRate)",
      "formatId=\(value.mFormatID)",
      "formatFlags=0x\(flags)",
      "bytesPerPacket=\(value.mBytesPerPacket)",
      "framesPerPacket=\(value.mFramesPerPacket)",
      "bytesPerFrame=\(value.mBytesPerFrame)",
      "channelsPerFrame=\(value.mChannelsPerFrame)",
      "bitsPerChannel=\(value.mBitsPerChannel)"
    ].joined(separator: " | ")
  }

  private static func describeAudioLevel(_ sampleBuffer: CMSampleBuffer) -> String {
    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return "unavailable"
    }

    let audioFormat = AVAudioFormat(streamDescription: streamDescription)
    let isNonInterleaved = (streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

    guard let audioFormat, audioFormat.commonFormat == .pcmFormatFloat32 else {
      let commonFormat = audioFormat.map { String($0.commonFormat.rawValue) } ?? "nil"
      return "unsupported commonFormat=\(commonFormat)"
    }

    var result = "unavailable"
    do {
      try sampleBuffer.withAudioBufferList { audioBufferList, _ in
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferList.unsafePointer) else {
          result = "pcm-buffer-create-failed"
          return
        }

        pcmBuffer.frameLength = pcmBuffer.frameCapacity

        guard let channelData = pcmBuffer.floatChannelData else {
          result = "missing-float-channel-data"
          return
        }

        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(audioFormat.channelCount)

        if frameCount == 0 || channelCount == 0 {
          result = "empty"
          return
        }

        var peak: Float = 0
        var sumSquares: Float = 0
        var sampleTotal = 0

        if isNonInterleaved {
          for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
              let sample = channel[frameIndex]
              peak = max(peak, abs(sample))
              sumSquares += sample * sample
              sampleTotal += 1
            }
          }
        } else {
          let samples = channelData[0]
          let totalSamples = frameCount * channelCount
          for sampleIndex in 0..<totalSamples {
            let sample = samples[sampleIndex]
            peak = max(peak, abs(sample))
            sumSquares += sample * sample
          }
          sampleTotal = totalSamples
        }

        if sampleTotal == 0 {
          result = "empty"
          return
        }

        let rms = sqrt(sumSquares / Float(sampleTotal))
        result = String(format: "rms=%.5f | peak=%.5f | frames=%d | channels=%d", rms, peak, frameCount, channelCount)
      }
    } catch {
      result = "level-read-failed: \(error.localizedDescription)"
    }

    return result
  }

  private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, audioFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
    var createdBuffer: AVAudioPCMBuffer?

    try sampleBuffer.withAudioBufferList { audioBufferList, _ in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferList.unsafePointer) else {
        return
      }

      buffer.frameLength = buffer.frameCapacity
      createdBuffer = buffer
    }

    guard let createdBuffer else {
      throw RecorderError.writerFailure("Unable to create AVAudioPCMBuffer from audio sample")
    }

    return createdBuffer
  }

  private func mixAudioFilesOffline(hasSystemAudio: Bool, hasMicrophoneAudio: Bool) throws -> URL {
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let mixSources = [
      hasSystemAudio ? try makeOfflineMixSource(url: systemAudioPath, kind: .system, outputFormat: outputFormat) : nil,
      hasMicrophoneAudio ? try makeOfflineMixSource(url: microphoneAudioPath, kind: .microphone, outputFormat: outputFormat) : nil
    ].compactMap { $0 }

    guard mixSources.isEmpty == false else {
      throw RecorderError.recordingUnavailable("No audio sources were captured for offline mix")
    }

    if FileManager.default.fileExists(atPath: rawAudioPath.path) {
      try? FileManager.default.removeItem(at: rawAudioPath)
    }

    let maxFrames = mixSources.reduce(Int64(0)) { currentMax, source in
      max(currentMax, source.startFrame + Int64(source.buffer.frameLength))
    }

    guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(maxFrames)) else {
      throw RecorderError.writerFailure("Unable to create offline mixed audio buffer")
    }

    mixedBuffer.frameLength = AVAudioFrameCount(maxFrames)
    zeroBuffer(mixedBuffer)

    for source in mixSources {
      Self.mixBuffer(source.buffer, into: mixedBuffer, startFrame: Int(source.startFrame), gain: source.kind == .microphone ? 0.8 : 1.0)
    }

    let mixedFile = try AVAudioFile(
      forWriting: rawAudioPath,
      settings: outputFormat.settings,
      commonFormat: outputFormat.commonFormat,
      interleaved: outputFormat.isInterleaved
    )

    try mixedFile.write(from: mixedBuffer)
    return rawAudioPath
  }

  private func makeOfflineMixSource(url: URL, kind: MixedAudioSourceKind, outputFormat: AVAudioFormat) throws -> OfflineMixSource {
    let sourceFile = try AVAudioFile(forReading: url)
    let sourceFrameLength = AVAudioFrameCount(sourceFile.length)

    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: sourceFrameLength) else {
      throw RecorderError.writerFailure("Unable to create source buffer for offline \(kind.rawValue) audio")
    }

    try sourceFile.read(into: sourceBuffer)
    let convertedBuffer = try Self.convertPCMBuffer(sourceBuffer, from: sourceFile.processingFormat, to: outputFormat)
    let startTime = (kind == .system ? systemAudioStartTime : microphoneAudioStartTime) ?? .zero
    let systemStart = systemAudioStartTime ?? startTime
    let delta = CMTimeSubtract(startTime, systemStart)
    let startSeconds = max(CMTimeGetSeconds(delta), 0)
    let startFrame = Int64((startSeconds * outputFormat.sampleRate).rounded())
    return OfflineMixSource(kind: kind, buffer: convertedBuffer, startFrame: startFrame)
  }

  private static func convertPCMBuffer(_ sourceBuffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if sourceFormat == targetFormat {
      return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw RecorderError.writerFailure("Unable to create AVAudioConverter for mixed audio")
    }

    let capacityRatio = targetFormat.sampleRate / sourceFormat.sampleRate
    let targetCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * capacityRatio)) + 32

    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
      throw RecorderError.writerFailure("Unable to create target mixed audio buffer")
    }

    var consumedSource = false
    var conversionError: NSError?
    let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
      if consumedSource {
        outStatus.pointee = .noDataNow
        return nil
      }

      consumedSource = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }

    if let conversionError {
      throw RecorderError.writerFailure("Unable to convert mixed audio buffer: \(conversionError.localizedDescription)")
    }

    guard status == .haveData || status == .inputRanDry else {
      throw RecorderError.writerFailure("Unexpected AVAudioConverter status for mixed audio: \(status.rawValue)")
    }

    return targetBuffer
  }

  private func zeroBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else {
      return
    }

    for channelIndex in 0..<Int(buffer.format.channelCount) {
      channelData[channelIndex].initialize(repeating: 0, count: Int(buffer.frameLength))
    }
  }

  private static func mixBuffer(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, startFrame: Int, gain: Float) {
    guard let sourceChannels = source.floatChannelData, let destinationChannels = destination.floatChannelData else {
      return
    }

    let sourceChannelCount = Int(source.format.channelCount)
    let destinationChannelCount = Int(destination.format.channelCount)
    let sourceFrameCount = Int(source.frameLength)

    for destinationChannelIndex in 0..<destinationChannelCount {
      let sourceChannelIndex = min(destinationChannelIndex, sourceChannelCount - 1)
      let sourceChannel = sourceChannels[sourceChannelIndex]
      let destinationChannel = destinationChannels[destinationChannelIndex]

      for frameIndex in 0..<sourceFrameCount {
        let destinationIndex = startFrame + frameIndex
        if destinationIndex >= Int(destination.frameLength) {
          break
        }

        let mixed = destinationChannel[destinationIndex] + (sourceChannel[frameIndex] * gain)
        destinationChannel[destinationIndex] = max(-1, min(1, mixed))
      }
    }
  }

  private static func makeEmptyPCMBuffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
    buffer.frameLength = frameCapacity

    if let floatChannelData = buffer.floatChannelData {
      for channelIndex in 0..<Int(format.channelCount) {
        floatChannelData[channelIndex].initialize(repeating: 0, count: Int(frameCapacity))
      }
    }

    return buffer
  }

  private static func copyBufferSamples(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
    guard let sourceChannels = source.floatChannelData, let destinationChannels = destination.floatChannelData else {
      return
    }

    let channelCount = min(Int(source.format.channelCount), Int(destination.format.channelCount))
    let frameCount = Int(source.frameLength)

    for channelIndex in 0..<channelCount {
      destinationChannels[channelIndex].update(from: sourceChannels[channelIndex], count: frameCount)
    }

    destination.frameLength = max(destination.frameLength, source.frameLength)
  }

  private static func mixSamples(from source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) {
    guard let sourceChannels = source.floatChannelData, let destinationChannels = destination.floatChannelData else {
      return
    }

    let channelCount = min(Int(source.format.channelCount), Int(destination.format.channelCount))
    let frameCount = Int(source.frameLength)
    let sourceGain: Float = 0.7

    for channelIndex in 0..<channelCount {
      let sourceChannel = sourceChannels[channelIndex]
      let destinationChannel = destinationChannels[channelIndex]

      for frameIndex in 0..<frameCount {
        let mixed = destinationChannel[frameIndex] + (sourceChannel[frameIndex] * sourceGain)
        destinationChannel[frameIndex] = max(-1, min(1, mixed))
      }
    }

    destination.frameLength = max(destination.frameLength, source.frameLength)
  }

  private static func videoDimensions(from sampleBuffer: CMSampleBuffer, fallbackWidth: Int, fallbackHeight: Int) -> (width: Int, height: Int) {
    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let width = CVPixelBufferGetWidth(imageBuffer)
      let height = CVPixelBufferGetHeight(imageBuffer)
      return (sanitizeVideoDimension(width), sanitizeVideoDimension(height))
    }

    return (sanitizeVideoDimension(fallbackWidth), sanitizeVideoDimension(fallbackHeight))
  }

  private static func sanitizeVideoDimension(_ value: Int) -> Int {
    let normalized = max(value, 2)
    return normalized.isMultiple(of: 2) ? normalized : normalized - 1
  }

  private static func describeVideoSampleFormat(_ sampleBuffer: CMSampleBuffer, dimensions: (width: Int, height: Int)) -> String {
    var parts = [
      "writerWidth=\(dimensions.width)",
      "writerHeight=\(dimensions.height)"
    ]

    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      let pixelWidth = CVPixelBufferGetWidth(imageBuffer)
      let pixelHeight = CVPixelBufferGetHeight(imageBuffer)
      let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
      parts.append("bufferWidth=\(pixelWidth)")
      parts.append("bufferHeight=\(pixelHeight)")
      parts.append("pixelFormat=\(pixelFormat)")
    }

    if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
      let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
      parts.append("mediaSubtype=\(mediaSubType)")
    }

    return parts.joined(separator: " | ")
  }

  private static func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let attachments = attachmentsArray.first,
      let statusRawValue = attachments[.status] as? Int
    else {
      return nil
    }

    return SCFrameStatus(rawValue: statusRawValue)
  }

  private func emitFirstVideoAppendDebugIfNeeded() {
    let shouldEmit = appendedFirstVideoFrame.withLock { state -> Bool in
      if state {
        return false
      }

      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Appended first video frame to AVAssetWriter",
      audioSummary: nil,
      sourceName: source.displayName
    )
  }

  private func emitSkippedVideoStatusDebugIfNeeded(_ status: SCFrameStatus) {
    let shouldEmit = loggedSkippedVideoStatus.withLock { previous -> Bool in
      if previous == status {
        return false
      }

      previous = status
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Skipping non-complete video frame with status=\(status.rawValue)",
      audioSummary: nil,
      sourceName: source.displayName
    )
  }

  private func emitProgressDebugIfNeeded(trigger: String) {
    let now = CFAbsoluteTimeGetCurrent()
    let shouldEmit = lastProgressLogTime.withLock { lastTime -> Bool in
      if now - lastTime < 5 {
        return false
      }

      lastTime = now
      return true
    }

    guard shouldEmit else {
      return
    }

    MacOSRecorderCLI.emitEvent(
      type: "debug",
      message: "Capture progress (\(trigger)): \(recordingSummary())",
      audioSummary: nil,
      sourceName: source.displayName
    )
  }

  private func recordingSummary() -> String {
    let videoSamples = videoSamplesReceived.withLock { $0 }
    let completeVideoFrames = completeVideoFramesReceived.withLock { $0 }
    let appendedVideoFrames = videoFramesAppended.withLock { $0 }
    let droppedVideoFrames = videoFramesDroppedNotReady.withLock { $0 }
    let systemBuffers = systemAudioBuffersWritten.withLock { $0 }
    let microphoneBuffers = microphoneAudioBuffersWritten.withLock { $0 }
    let lastVideo = lastVideoSampleTime.withLock { $0 }
    let lastCompleteVideo = lastCompleteVideoSampleTime.withLock { $0 }
    let lastSystemAudio = lastSystemAudioSampleTime.withLock { $0 }
    let lastMicrophoneAudio = lastMicrophoneAudioSampleTime.withLock { $0 }

    return [
      "videoSamples=\(videoSamples)",
      "completeVideoFrames=\(completeVideoFrames)",
      "videoFramesAppended=\(appendedVideoFrames)",
      "videoFramesDroppedNotReady=\(droppedVideoFrames)",
      "systemAudioBuffersWritten=\(systemBuffers)",
      "microphoneAudioBuffersWritten=\(microphoneBuffers)",
      "lastVideoPTS=\(Self.describeTime(lastVideo))",
      "lastCompleteVideoPTS=\(Self.describeTime(lastCompleteVideo))",
      "lastSystemAudioPTS=\(Self.describeTime(lastSystemAudio))",
      "lastMicrophonePTS=\(Self.describeTime(lastMicrophoneAudio))"
    ].joined(separator: " | ")
  }

  private func outputFileSummary() -> String {
    let videoDuration = Self.describeAssetDuration(at: options.videoPath)
    let audioDuration = Self.describeAssetDuration(at: options.audioPath)
    let systemAudioDuration = Self.describePCMFileDuration(at: systemAudioPath)
    let microphoneAudioDuration = Self.describePCMFileDuration(at: microphoneAudioPath)
    let rawAudioDuration = Self.describePCMFileDuration(at: rawAudioPath)

    return [
      "outputDurations",
      "video.mov=\(videoDuration)",
      "audio.m4a=\(audioDuration)",
      "system-audio.caf=\(systemAudioDuration)",
      "microphone-audio.caf=\(microphoneAudioDuration)",
      "audio-raw.caf=\(rawAudioDuration)"
    ].joined(separator: " | ")
  }

  private static func describeTime(_ time: CMTime?) -> String {
    guard let time else {
      return "nil"
    }

    guard time.isNumeric else {
      return "non-numeric"
    }

    return String(format: "%.3fs", time.seconds)
  }

  private static func describeAssetDuration(at url: URL) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return "missing"
    }

    let asset = AVURLAsset(url: url)
    let duration = asset.duration

    guard duration.isNumeric else {
      return "non-numeric"
    }

    return String(format: "%.3fs", duration.seconds)
  }

  private static func describePCMFileDuration(at url: URL) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return "missing"
    }

    do {
      let file = try AVAudioFile(forReading: url)
      let seconds = Double(file.length) / file.processingFormat.sampleRate
      return String(format: "%.3fs", seconds)
    } catch {
      return "unreadable"
    }
  }

  private static func describeRect(_ rect: CGRect?) -> String {
    guard let rect else {
      return "nil"
    }

    return "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))"
  }

  private func resolveRecordingCompletion(_ result: Result<Void, Error>) {
    let handler = completionHandler.withLock { handler -> ((Result<Void, Error>) -> Void)? in
      let current = handler
      handler = nil
      return current
    }

    handler?(result)
  }
}

final class LockedState<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) {
    self.value = value
  }

  func withLock<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

Task { @MainActor in
  do {
    _ = NSApplication.shared
    _ = NSApp.setActivationPolicy(.prohibited)
    try await MacOSRecorderCLI.run()
    exit(0)
  } catch {
    MacOSRecorderCLI.emitEvent(type: "error", message: error.localizedDescription, audioSummary: nil, sourceName: nil)
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
  }
}

dispatchMain()
