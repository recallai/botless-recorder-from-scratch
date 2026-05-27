import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum ProbeError: Error, LocalizedError {
  case invalidArguments(String)
  case missingSource(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message), .missingSource(let message):
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

struct OfflineMixSource {
  let kind: MixedAudioSourceKind
  let buffer: AVAudioPCMBuffer
  let startFrame: Int64
}

enum MeetingMuteState: String {
  case muted
  case unmuted
  case unknown
}

struct ProbeSummary: Codable {
  let sourceId: String
  let sourceName: String
  let durationSeconds: Double
  let videoSamples: Int
  let completeFrames: Int
  let audioSamples: Int
  let microphoneSamples: Int
  let lastVideoPTS: Double?
  let lastAudioPTS: Double?
  let lastMicrophonePTS: Double?
  let firstStreamError: String?
  let sourceEvents: [String]
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

  var owningApplication: String? {
    switch self {
    case .display:
      return nil
    case .window(let window):
      return window.owningApplication?.applicationName
    }
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
final class AppManagedWindowProbe: NSObject, SCStreamOutput, SCStreamDelegate {
  private let sourceId: String
  private let source: CaptureSourceReference
  private let videoPath: URL?
  private let audioPath: URL?
  private let captureMicrophone: Bool
  private let meetingUrl: String?
  private let rawAudioPath: URL?
  private let systemAudioPath: URL?
  private let microphoneAudioPath: URL?
  private var stream: SCStream!
  private let videoQueue = DispatchQueue(label: "botless-notetaker.app-managed-probe.video", qos: .userInitiated)
  private let audioQueue = DispatchQueue(label: "botless-notetaker.app-managed-probe.audio", qos: .userInitiated)
  private let microphoneQueue = DispatchQueue(label: "botless-notetaker.app-managed-probe.microphone", qos: .userInitiated)
  private let videoWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var systemAudioFile: AVAudioFile?
  private var microphoneAudioFile: AVAudioFile?
  private let videoSamples = LockedState(0)
  private let completeFrames = LockedState(0)
  private let audioSamples = LockedState(0)
  private let microphoneSamples = LockedState(0)
  private let lastVideoPTS = LockedState<CMTime?>(nil)
  private let lastAudioPTS = LockedState<CMTime?>(nil)
  private let lastMicrophonePTS = LockedState<CMTime?>(nil)
  private let lastProgressLogTime = LockedState<CFAbsoluteTime>(0)
  private let completionHandler = LockedState<((Result<Void, Error>) -> Void)?>(nil)
  private let finishing = LockedState(false)
  private let didEmitStartedEvent = LockedState(false)
  private let startedAt = LockedState<CMTime?>(nil)
  private let meetingMuteState = LockedState<MeetingMuteState>(.unknown)
  private let muteMonitorTask = LockedState<Task<Void, Never>?>(nil)
  private var systemAudioStartTime: CMTime?
  private var microphoneAudioStartTime: CMTime?

  init(sourceId: String, videoPath: URL?, audioPath: URL?, captureMicrophone: Bool, meetingUrl: String?) async throws {
    self.sourceId = sourceId
    self.videoPath = videoPath
    self.audioPath = audioPath
    self.captureMicrophone = captureMicrophone
    self.meetingUrl = meetingUrl
    self.rawAudioPath = audioPath.map { $0.deletingLastPathComponent().appendingPathComponent("audio-raw.caf") }
    self.systemAudioPath = audioPath.map { $0.deletingLastPathComponent().appendingPathComponent("system-audio.caf") }
    self.microphoneAudioPath = audioPath.map { $0.deletingLastPathComponent().appendingPathComponent("microphone-audio.caf") }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    self.source = try WindowProbe.resolveSource(sourceId: sourceId, content: content)
    self.videoWriter = try videoPath.map { try AVAssetWriter(outputURL: $0, fileType: .mov) }
    super.init()

    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.captureMicrophone = captureMicrophone
    configuration.excludesCurrentProcessAudio = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 6
    configuration.width = max(source.width, 2)
    configuration.height = max(source.height, 2)

    let filter = try WindowProbe.makeContentFilter(for: source)
    self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    if captureMicrophone {
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
    }
  }

  func runUntilInterrupted() async throws {
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
          Self.emitEvent(type: "debug", message: "Prepared native source \(self.source.displayName) origin=\(self.source.originX),\(self.source.originY) size=\(self.source.width)x\(self.source.height) videoPath=\(self.videoPath?.path ?? "none") audioPath=\(self.audioPath?.path ?? "none")", sourceName: self.source.displayName)
          Self.emitEvent(type: "debug", message: "Starting SCStream capture", sourceName: self.source.displayName)
          try await self.stream.startCapture()
          Self.emitEvent(type: "debug", message: "SCStream capture started", sourceName: self.source.displayName)
          self.startMuteMonitorIfNeeded()
          self.emitStartedEventIfNeeded()
        } catch {
          self.resolveCompletion(.failure(error))
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
      videoSamples.withLock { $0 += 1 }
      lastVideoPTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
      guard let status = WindowProbe.frameStatus(for: sampleBuffer), status == .complete else {
        return
      }

      completeFrames.withLock { $0 += 1 }
      appendVideoIfConfigured(sampleBuffer)
      emitProgressDebugIfNeeded(trigger: "video")
    case .audio:
      audioSamples.withLock { $0 += 1 }
      lastAudioPTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
      appendAudioIfConfigured(sampleBuffer, source: .system)
      emitProgressDebugIfNeeded(trigger: "system")
    case .microphone:
      microphoneSamples.withLock { $0 += 1 }
      lastMicrophonePTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
      appendAudioIfConfigured(sampleBuffer, source: .microphone)
      emitProgressDebugIfNeeded(trigger: "microphone")
    default:
      break
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Self.emitEvent(type: "error", message: "SCStream stopped with error: \(error.localizedDescription)", sourceName: source.displayName)

    Task { @MainActor in
      do {
        try await self.stop()
        self.resolveCompletion(.failure(error))
      } catch {
        Self.emitEvent(
          type: "error",
          message: "Failed to finalize after SCStream interruption: \(error.localizedDescription)",
          sourceName: self.source.displayName
        )
        self.resolveCompletion(.failure(error))
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
      if !message.contains("already stopped") && !message.contains("does not exist") {
        throw error
      }
    }

    stopMuteMonitor()

    if let videoWriter {
      videoInput?.markAsFinished()

      if videoWriter.status == .writing {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          videoWriter.finishWriting {
            continuation.resume()
          }
        }
      }

      Self.emitEvent(type: "debug", message: "Video writer finished with status=\(videoWriter.status.rawValue) path=\(videoPath?.path ?? "unknown")", sourceName: source.displayName)
    }

    try await exportAudioFileIfNeeded()

    Self.emitEvent(type: "debug", message: debugSummary(), sourceName: source.displayName)
    Self.emitEvent(type: "recording-stopped", message: nil, sourceName: nil)
  }

  private func emitStartedEventIfNeeded() {
    let shouldEmit = didEmitStartedEvent.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }

    guard shouldEmit else {
      return
    }

    let summary = [
      videoPath == nil ? "no video file" : "video.mov is being written",
      audioPath == nil ? "no audio file" : "audio.m4a will be exported on stop",
      captureMicrophone ? "microphone enabled" : "microphone disabled"
    ].joined(separator: " | ")
    Self.emitEvent(type: "recording-started", message: nil, audioSummary: summary, sourceName: source.displayName)
  }

  private func appendVideoIfConfigured(_ sampleBuffer: CMSampleBuffer) {
    guard let videoWriter else {
      return
    }

    do {
      try ensureVideoInput(using: sampleBuffer)
      try startVideoWriterIfNeeded(using: sampleBuffer)
    } catch {
      Self.emitEvent(type: "error", message: error.localizedDescription, sourceName: source.displayName)
      return
    }

    guard let videoInput, videoWriter.status == .writing, videoInput.isReadyForMoreMediaData else {
      return
    }

    if !videoInput.append(sampleBuffer) {
      Self.emitEvent(type: "error", message: "Video append failed: \(writerErrorDescription(videoWriter))", sourceName: source.displayName)
    }
  }

  private func appendAudioIfConfigured(_ sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) {
    guard audioPath != nil else {
      return
    }

    if source == .microphone && captureMicrophone && shouldSuppressMicrophoneSample() {
      return
    }

    do {
      let (audioFile, pcmBuffer) = try ensureAudioFileAndBuffer(from: sampleBuffer, source: source)
      try audioFile.write(from: pcmBuffer)
    } catch {
      Self.emitEvent(type: "error", message: error.localizedDescription, sourceName: self.source.displayName)
    }
  }

  private func ensureVideoInput(using sampleBuffer: CMSampleBuffer) throws {
    if videoInput != nil {
      return
    }

    guard let videoWriter else {
      return
    }

    let dimensions = videoDimensions(from: sampleBuffer, fallbackWidth: source.width, fallbackHeight: source.height)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: dimensions.width,
      AVVideoHeightKey: dimensions.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: max(dimensions.width * dimensions.height * 6, 8_000_000),
        AVVideoMaxKeyFrameIntervalKey: 30
      ]
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
    input.expectsMediaDataInRealTime = true

    guard videoWriter.canAdd(input) else {
      throw ProbeError.invalidArguments("Unable to add video input to AVAssetWriter")
    }

    videoWriter.add(input)
    videoInput = input
  }

  private func startVideoWriterIfNeeded(using sampleBuffer: CMSampleBuffer) throws {
    guard let videoWriter else {
      return
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
      throw ProbeError.invalidArguments("Video writer failed to start: \(writerErrorDescription(videoWriter))")
    }

    videoWriter.startSession(atSourceTime: presentationTime)
    Self.emitEvent(type: "debug", message: "Video writer started at \(presentationTime.seconds)s", sourceName: source.displayName)
  }

  private func ensureAudioFileAndBuffer(from sampleBuffer: CMSampleBuffer, source: MixedAudioSourceKind) throws -> (AVAudioFile, AVAudioPCMBuffer) {
    guard
      let targetAudioPath = audioPath,
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
      let audioFormat = AVAudioFormat(streamDescription: streamDescription)
    else {
      throw ProbeError.invalidArguments("Unable to inspect \(source.rawValue) audio sample format")
    }

    let file: AVAudioFile
    switch source {
    case .system:
      if systemAudioFile == nil {
        let systemPath = systemAudioPath ?? targetAudioPath.deletingLastPathComponent().appendingPathComponent("system-audio.caf")
        systemAudioFile = try AVAudioFile(forWriting: systemPath, settings: audioFormat.settings, commonFormat: audioFormat.commonFormat, interleaved: audioFormat.isInterleaved)
      }
      guard let systemAudioFile else {
        throw ProbeError.invalidArguments("Unable to create system audio file")
      }
      file = systemAudioFile
      if systemAudioStartTime == nil {
        systemAudioStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      }
    case .microphone:
      if microphoneAudioFile == nil {
        let microphonePath = microphoneAudioPath ?? targetAudioPath.deletingLastPathComponent().appendingPathComponent("microphone-audio.caf")
        microphoneAudioFile = try AVAudioFile(forWriting: microphonePath, settings: audioFormat.settings, commonFormat: audioFormat.commonFormat, interleaved: audioFormat.isInterleaved)
      }
      guard let microphoneAudioFile else {
        throw ProbeError.invalidArguments("Unable to create microphone audio file")
      }
      file = microphoneAudioFile
      if microphoneAudioStartTime == nil {
        microphoneAudioStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      }
    }

    var createdBuffer: AVAudioPCMBuffer?
    try sampleBuffer.withAudioBufferList { audioBufferList, _ in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferList.unsafePointer) else {
        return
      }
      buffer.frameLength = buffer.frameCapacity
      createdBuffer = buffer
    }

    guard let createdBuffer else {
      throw ProbeError.invalidArguments("Unable to create AVAudioPCMBuffer from audio sample")
    }

    return (file, createdBuffer)
  }

  private func shouldSuppressMicrophoneSample() -> Bool {
    meetingMuteState.withLock { $0 == .muted }
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

    Self.emitEvent(type: "debug", message: "Capture progress (\(trigger)): \(debugSummary())", sourceName: source.displayName)
  }

  private func startMuteMonitorIfNeeded() {
    guard captureMicrophone, let meetingUrl, meetingUrl.isEmpty == false else {
      return
    }

    let task = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        let state = self.queryMuteState(meetingUrl: meetingUrl)
        self.applyMuteState(state)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }

    muteMonitorTask.withLock { current in
      current?.cancel()
      current = task
    }
  }

  private func stopMuteMonitor() {
    muteMonitorTask.withLock { task in
      task?.cancel()
      task = nil
    }
  }

  private func applyMuteState(_ nextState: MeetingMuteState) {
    let previousState = meetingMuteState.withLock { state -> MeetingMuteState in
      let previous = state
      state = nextState
      return previous
    }

    guard previousState != nextState else {
      return
    }

    switch nextState {
    case .muted:
      Self.emitEvent(type: "debug", message: "Meet mute detection: local microphone is muted; suppressing microphone samples", sourceName: source.displayName)
    case .unmuted:
      Self.emitEvent(type: "debug", message: "Meet mute detection: local microphone is unmuted; recording microphone samples", sourceName: source.displayName)
    case .unknown:
      Self.emitEvent(type: "debug", message: "Meet mute detection: mute state unavailable; microphone capture will continue", sourceName: source.displayName)
    }
  }

  private func queryMuteState(meetingUrl: String) -> MeetingMuteState {
    let script = muteStateScript(for: meetingUrl)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus != 0 {
        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if errorText.contains("Allow JavaScript from Apple Events") || errorText.contains("(12)") {
          return .unknown
        }
        return .unknown
      }

      let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      if output.hasPrefix("muted:") {
        return .muted
      }
      if output.hasPrefix("unmuted:") {
        return .unmuted
      }
      return .unknown
    } catch {
      return .unknown
    }
  }

  private func muteStateScript(for meetingUrl: String) -> String {
    let meetingCodeMatch = meetingUrl.range(of: #"meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})"#, options: .regularExpression)
    let meetingCode = meetingCodeMatch.map { String(meetingUrl[$0]).replacingOccurrences(of: "meet.google.com/", with: "") } ?? ""
    let escapedMeetingUrl = meetingUrl.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let escapedMeetingCode = meetingCode.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let javascript = [
      "(()=>{",
      "const normalize=(value)=>String(value||'').toLowerCase().replace(/\\s+/g,' ').trim();",
      "const controls=Array.from(document.querySelectorAll('button,[role=button],[aria-label],[title]'));",
      "for(const element of controls){",
      "const values=[element.getAttribute('aria-label'),element.getAttribute('title'),element.textContent].map(normalize).filter(Boolean);",
      "if(values.some((value)=>value.includes('turn on microphone')||value==='unmute'||value.includes('unmute microphone'))){return 'muted:'+values.join('|');}",
      "if(values.some((value)=>value.includes('turn off microphone')||value==='mute'||value.includes('mute microphone'))){return 'unmuted:'+values.join('|');}",
      "}",
      "return 'unknown';",
      "})();"
    ].joined().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

    return """
      set targetUrl to "\(escapedMeetingUrl)"
      set targetMeetingCode to "\(escapedMeetingCode)"
      set muteJavascript to "\(javascript)"

      tell application "Google Chrome"
        if not running then
          return "unknown"
        end if

        set targetTab to missing value

        repeat with windowRef in every window
          repeat with tabRef in every tab of windowRef
            try
              set tabUrl to (URL of tabRef as text)

              if tabUrl is targetUrl then
                set targetTab to tabRef
                exit repeat
              end if

              if targetMeetingCode is not "" and tabUrl contains ("meet.google.com/" & targetMeetingCode) then
                set targetTab to tabRef
                exit repeat
              end if
            end try
          end repeat

          if targetTab is not missing value then
            exit repeat
          end if
        end repeat

        if targetTab is missing value then
          return "unknown"
        end if

        return execute targetTab javascript muteJavascript
      end tell
      """
  }

  private func debugSummary() -> String {
    let videoSamples = videoSamples.withLock { $0 }
    let completeFrames = completeFrames.withLock { $0 }
    let audioSamples = audioSamples.withLock { $0 }
    let microphoneSamples = microphoneSamples.withLock { $0 }
    let lastVideo = lastVideoPTS.withLock { $0 }
    let lastAudio = lastAudioPTS.withLock { $0 }
    let lastMicrophone = lastMicrophonePTS.withLock { $0 }

    return [
      "videoSamples=\(videoSamples)",
      "completeVideoFrames=\(completeFrames)",
      "audioSamples=\(audioSamples)",
      "microphoneSamples=\(microphoneSamples)",
      "lastVideoPTS=\(Self.describeTime(lastVideo))",
      "lastAudioPTS=\(Self.describeTime(lastAudio))",
      "lastMicrophonePTS=\(Self.describeTime(lastMicrophone))"
    ].joined(separator: " | ")
  }

  private func writerErrorDescription(_ writer: AVAssetWriter) -> String {
    guard let error = writer.error else {
      return "unknown writer error"
    }

    let nsError = error as NSError
    return "\(error.localizedDescription) | domain=\(nsError.domain) | code=\(nsError.code)"
  }

  private func exportAudioFileIfNeeded() async throws {
    guard let audioPath else {
      return
    }

    let hasSystemAudio = systemAudioPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let hasMicrophoneAudio = microphoneAudioPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

    guard hasSystemAudio || hasMicrophoneAudio else {
      return
    }

    let mixedUrl = try mixAudioFilesOffline(hasSystemAudio: hasSystemAudio, hasMicrophoneAudio: hasMicrophoneAudio)

    if FileManager.default.fileExists(atPath: audioPath.path) {
      try? FileManager.default.removeItem(at: audioPath)
    }

    let asset = AVURLAsset(url: mixedUrl)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw ProbeError.invalidArguments("Unable to create audio export session")
    }

    exportSession.outputURL = audioPath
    exportSession.outputFileType = .m4a

    try await exportSession.export(to: audioPath, as: .m4a)
    cleanupIntermediateAudioFiles()
    Self.emitEvent(type: "debug", message: "Audio file finalized path=\(audioPath.path)", sourceName: source.displayName)
  }

  private func cleanupIntermediateAudioFiles() {
    for path in [rawAudioPath, systemAudioPath, microphoneAudioPath].compactMap({ $0 }) where FileManager.default.fileExists(atPath: path.path) {
      try? FileManager.default.removeItem(at: path)
    }
  }

  private func mixAudioFilesOffline(hasSystemAudio: Bool, hasMicrophoneAudio: Bool) throws -> URL {
    guard let rawAudioPath else {
      throw ProbeError.invalidArguments("Missing raw audio path")
    }

    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let mixSources = [
      hasSystemAudio && systemAudioPath != nil ? try makeOfflineMixSource(url: systemAudioPath!, kind: .system, outputFormat: outputFormat) : nil,
      hasMicrophoneAudio && microphoneAudioPath != nil ? try makeOfflineMixSource(url: microphoneAudioPath!, kind: .microphone, outputFormat: outputFormat) : nil
    ].compactMap { $0 }

    guard !mixSources.isEmpty else {
      throw ProbeError.invalidArguments("No audio sources were captured for offline mix")
    }

    if FileManager.default.fileExists(atPath: rawAudioPath.path) {
      try? FileManager.default.removeItem(at: rawAudioPath)
    }

    let maxFrames = mixSources.reduce(Int64(0)) { max($0, $1.startFrame + Int64($1.buffer.frameLength)) }
    guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(maxFrames)) else {
      throw ProbeError.invalidArguments("Unable to create offline mixed audio buffer")
    }
    mixedBuffer.frameLength = AVAudioFrameCount(maxFrames)
    zeroBuffer(mixedBuffer)

    for source in mixSources {
      Self.mixBuffer(source.buffer, into: mixedBuffer, startFrame: Int(source.startFrame), gain: source.kind == .microphone ? 0.8 : 1.0)
    }

    let mixedFile = try AVAudioFile(forWriting: rawAudioPath, settings: outputFormat.settings, commonFormat: outputFormat.commonFormat, interleaved: outputFormat.isInterleaved)
    try mixedFile.write(from: mixedBuffer)
    return rawAudioPath
  }

  private func makeOfflineMixSource(url: URL, kind: MixedAudioSourceKind, outputFormat: AVAudioFormat) throws -> OfflineMixSource {
    let sourceFile = try AVAudioFile(forReading: url)
    let sourceFrameLength = AVAudioFrameCount(sourceFile.length)

    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: sourceFrameLength) else {
      throw ProbeError.invalidArguments("Unable to create source buffer for offline \(kind.rawValue) audio")
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
      throw ProbeError.invalidArguments("Unable to create AVAudioConverter for mixed audio")
    }

    let capacityRatio = targetFormat.sampleRate / sourceFormat.sampleRate
    let targetCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * capacityRatio)) + 32
    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
      throw ProbeError.invalidArguments("Unable to create target mixed audio buffer")
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
      throw ProbeError.invalidArguments("Unable to convert mixed audio buffer: \(conversionError.localizedDescription)")
    }

    guard status == .haveData || status == .inputRanDry else {
      throw ProbeError.invalidArguments("Unexpected AVAudioConverter status for mixed audio: \(status.rawValue)")
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

  private func videoDimensions(from sampleBuffer: CMSampleBuffer, fallbackWidth: Int, fallbackHeight: Int) -> (width: Int, height: Int) {
    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      return (sanitizeVideoDimension(CVPixelBufferGetWidth(imageBuffer)), sanitizeVideoDimension(CVPixelBufferGetHeight(imageBuffer)))
    }

    return (sanitizeVideoDimension(fallbackWidth), sanitizeVideoDimension(fallbackHeight))
  }

  private func sanitizeVideoDimension(_ value: Int) -> Int {
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

  private static func emitEvent(type: String, message: String?, audioSummary: String? = nil, sourceName: String?) {
    let event = EventMessage(type: type, message: message, audioSummary: audioSummary, sourceName: sourceName)
    guard let data = try? JSONEncoder().encode(event), let line = String(data: data, encoding: .utf8) else {
      return
    }
    print(line)
    fflush(stdout)
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
final class WindowProbe: NSObject, SCStreamOutput, SCStreamDelegate {
  private let sourceId: String
  private let durationSeconds: Double
  private let captureSystemAudio: Bool
  private let captureMicrophone: Bool
  private let source: CaptureSourceReference
  private var stream: SCStream!
  private let videoQueue = DispatchQueue(label: "botless-notetaker.window-probe.video", qos: .userInitiated)
  private let audioQueue = DispatchQueue(label: "botless-notetaker.window-probe.audio", qos: .userInitiated)
  private let microphoneQueue = DispatchQueue(label: "botless-notetaker.window-probe.microphone", qos: .userInitiated)
  private let videoSamples = LockedState(0)
  private let completeFrames = LockedState(0)
  private let audioSamples = LockedState(0)
  private let microphoneSamples = LockedState(0)
  private let lastVideoPTS = LockedState<CMTime?>(nil)
  private let lastAudioPTS = LockedState<CMTime?>(nil)
  private let lastMicrophonePTS = LockedState<CMTime?>(nil)
  private let firstStreamError = LockedState<String?>(nil)
  private let sourceEvents = LockedState<[String]>([])
  private let sourceIdStillPresent = LockedState(true)
  private let sourceWatchTask = LockedState<Task<Void, Never>?>(nil)

  init(sourceId: String, durationSeconds: Double, captureSystemAudio: Bool, captureMicrophone: Bool) async throws {
    self.sourceId = sourceId
    self.durationSeconds = durationSeconds
    self.captureSystemAudio = captureSystemAudio
    self.captureMicrophone = captureMicrophone
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    self.source = try Self.resolveSource(sourceId: sourceId, content: content)
    super.init()

    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = captureSystemAudio
    configuration.captureMicrophone = captureMicrophone
    configuration.excludesCurrentProcessAudio = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 6
    configuration.width = max(source.width, 2)
    configuration.height = max(source.height, 2)

    let filter = try Self.makeContentFilter(for: source)
    self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
    if captureSystemAudio {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    }
    if captureMicrophone {
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
    }
  }

  func run() async throws -> ProbeSummary {
    print("Starting probe for \(source.displayName) (\(sourceId)) for \(durationSeconds)s systemAudio=\(captureSystemAudio) microphone=\(captureMicrophone)")
    recordSourceEvent("initial-source id=\(sourceId) name=\(source.displayName) app=\(source.owningApplication ?? "unknown") frame=\(source.originX),\(source.originY) \(source.width)x\(source.height)")
    try await stream.startCapture()
    print("SCStream started")
    startWatchingSource()

    try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))

    stopWatchingSource()

    do {
      try await stream.stopCapture()
    } catch {
      let message = error.localizedDescription
      if !message.contains("already stopped") && !message.contains("does not exist") {
        throw error
      }
    }

    return ProbeSummary(
      sourceId: sourceId,
      sourceName: source.displayName,
      durationSeconds: durationSeconds,
      videoSamples: videoSamples.withLock { $0 },
      completeFrames: completeFrames.withLock { $0 },
      audioSamples: audioSamples.withLock { $0 },
      microphoneSamples: microphoneSamples.withLock { $0 },
      lastVideoPTS: lastVideoPTS.withLock { $0?.seconds },
      lastAudioPTS: lastAudioPTS.withLock { $0?.seconds },
      lastMicrophonePTS: lastMicrophonePTS.withLock { $0?.seconds },
      firstStreamError: firstStreamError.withLock { $0 },
      sourceEvents: sourceEvents.withLock { $0 }
    )
  }

  nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard CMSampleBufferIsValid(sampleBuffer) else {
      return
    }

    switch outputType {
    case .screen:
      videoSamples.withLock { $0 += 1 }
      lastVideoPTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }

      if let status = Self.frameStatus(for: sampleBuffer), status == .complete {
        completeFrames.withLock { $0 += 1 }
      }
    case .audio:
      audioSamples.withLock { $0 += 1 }
      lastAudioPTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    case .microphone:
      microphoneSamples.withLock { $0 += 1 }
      lastMicrophonePTS.withLock { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    default:
      break
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    let message = error.localizedDescription
    print("SCStream stopped with error: \(message)")
    recordSourceEvent("stream-error \(message)")
    firstStreamError.withLock { current in
      if current == nil {
        current = message
      }
    }
  }

  private func startWatchingSource() {
    let task = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        await self.pollSourceState()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }

    sourceWatchTask.withLock { existing in
      existing?.cancel()
      existing = task
    }
  }

  private func stopWatchingSource() {
    sourceWatchTask.withLock { task in
      task?.cancel()
      task = nil
    }
  }

  @MainActor
  private func pollSourceState() async {
    guard case .window = source else {
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let windows = content.windows.filter { $0.isOnScreen }
      let exactMatch = windows.first(where: { "window:\($0.windowID)" == sourceId })

      if let exactMatch {
        let wasMissing = sourceIdStillPresent.withLock { present -> Bool in
          let previous = present
          present = true
          return !previous
        }

        if wasMissing {
          recordSourceEvent("source-returned id=\(sourceId) title=\(exactMatch.title ?? "") frame=\(Int(exactMatch.frame.origin.x)),\(Int(exactMatch.frame.origin.y)) \(Int(exactMatch.frame.width))x\(Int(exactMatch.frame.height))")
        }

        return
      }

      let justWentMissing = sourceIdStillPresent.withLock { present -> Bool in
        let previous = present
        present = false
        return previous
      }

      guard justWentMissing else {
        return
      }

      recordSourceEvent("source-missing id=\(sourceId)")

      let replacements = windows
        .filter { ($0.owningApplication?.applicationName ?? "") == source.owningApplication }
        .map { window -> String in
          let title = window.title ?? ""
          return "candidate id=window:\(window.windowID) title=\(title) frame=\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) \(Int(window.frame.width))x\(Int(window.frame.height))"
        }
        .prefix(8)

      if replacements.isEmpty {
        recordSourceEvent("source-missing no-same-app-candidates")
      } else {
        for candidate in replacements {
          recordSourceEvent(candidate)
        }
      }
    } catch {
      recordSourceEvent("source-watch-error \(error.localizedDescription)")
    }
  }

  private func recordSourceEvent(_ message: String) {
    let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
    let line = "[\(timestamp)] \(message)"
    print("SOURCE_EVENT \(line)")
    sourceEvents.withLock { $0.append(line) }
  }

  static func resolveSource(sourceId: String, content: SCShareableContent) throws -> CaptureSourceReference {
    if sourceId.hasPrefix("display:"), let id = UInt32(sourceId.replacingOccurrences(of: "display:", with: "")) {
      guard let display = content.displays.first(where: { $0.displayID == id }) else {
        throw ProbeError.missingSource("Display source not found: \(sourceId)")
      }
      return .display(display)
    }

    if sourceId.hasPrefix("window:"), let id = UInt32(sourceId.replacingOccurrences(of: "window:", with: "")) {
      guard let window = content.windows.first(where: { $0.windowID == id }) else {
        throw ProbeError.missingSource("Window source not found: \(sourceId)")
      }
      return .window(window)
    }

    throw ProbeError.invalidArguments("Unknown source id: \(sourceId)")
  }

  static func makeContentFilter(for source: CaptureSourceReference) throws -> SCContentFilter {
    switch source {
    case .display(let display):
      return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    case .window(let window):
      return SCContentFilter(desktopIndependentWindow: window)
    }
  }

  static func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let attachments = attachmentsArray.first,
      let statusRawValue = attachments[.status] as? Int
    else {
      return nil
    }

    return SCFrameStatus(rawValue: statusRawValue)
  }
}

@MainActor
func listSources() async throws {
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

  let response = SourceListResponse(sources: windows + displays)
  let data = try JSONEncoder().encode(response)
  FileHandle.standardOutput.write(data)
}

@MainActor
func main() async throws {
  _ = NSApplication.shared
  _ = NSApp.setActivationPolicy(.prohibited)

  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    throw ProbeError.invalidArguments("Expected a command: list-sources, probe-window, or app-probe")
  }

  switch command {
  case "list-sources":
    try await listSources()
  case "probe-window":
    var values: [String: String] = [:]
    var index = 1
    while index < arguments.count {
      let key = arguments[index]
      let nextIndex = index + 1
      guard key.hasPrefix("--"), nextIndex < arguments.count else {
        throw ProbeError.invalidArguments("Invalid argument list")
      }
      values[String(key.dropFirst(2))] = arguments[nextIndex]
      index += 2
    }

    guard let sourceId = values["source-id"] else {
      throw ProbeError.invalidArguments("Missing --source-id")
    }

      let durationSeconds = values["duration-seconds"].flatMap(Double.init) ?? 10
      let captureSystemAudio = values["capture-system-audio"] == "true"
      let captureMicrophone = values["capture-microphone"] == "true"
      let probe = try await WindowProbe(
        sourceId: sourceId,
        durationSeconds: durationSeconds,
        captureSystemAudio: captureSystemAudio,
        captureMicrophone: captureMicrophone
      )
      let summary = try await probe.run()
      let data = try JSONEncoder().encode(summary)
      FileHandle.standardOutput.write(data)
  case "app-probe":
    var values: [String: String] = [:]
    var index = 1
    while index < arguments.count {
      let key = arguments[index]
      let nextIndex = index + 1
      guard key.hasPrefix("--"), nextIndex < arguments.count else {
        throw ProbeError.invalidArguments("Invalid argument list")
      }
      values[String(key.dropFirst(2))] = arguments[nextIndex]
      index += 2
    }

    guard let sourceId = values["source-id"] else {
      throw ProbeError.invalidArguments("Missing --source-id")
    }

    let videoPath = values["video-path"].map { URL(fileURLWithPath: $0) }
    let audioPath = values["audio-path"].map { URL(fileURLWithPath: $0) }
    let captureMicrophone = values["capture-microphone"] == "true"
    let meetingUrl = values["meeting-url"]
    let probe = try await AppManagedWindowProbe(sourceId: sourceId, videoPath: videoPath, audioPath: audioPath, captureMicrophone: captureMicrophone, meetingUrl: meetingUrl)
    try await probe.runUntilInterrupted()
  default:
    throw ProbeError.invalidArguments("Unknown command: \(command)")
  }
}

Task {
  do {
    try await main()
    exit(0)
  } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
  }
}

dispatchMain()
