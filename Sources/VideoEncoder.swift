import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

enum VideoEncoderError: LocalizedError {
  case pixelBuffer(CVReturn)
  case missingPixelBuffer
  case transferSession(OSStatus)
  case pixelBufferPool
  case compressionSession(OSStatus)
  case compressionProperties(OSStatus)
  case prepare(OSStatus)
  case transfer(OSStatus)
  case encode(OSStatus)

  var errorDescription: String? {
    switch self {
    case let .pixelBuffer(status): return "could not wrap IOSurface in CVPixelBuffer (\(status))"
    case .missingPixelBuffer: return "CVPixelBufferCreateWithIOSurface returned no buffer"
    case let .transferSession(status): return "could not create VTPixelTransferSession (\(status))"
    case .pixelBufferPool: return "could not create the NV12 pixel buffer pool"
    case let .compressionSession(status): return "could not create H.264 encoder (\(status))"
    case let .compressionProperties(status): return "could not configure H.264 encoder (\(status))"
    case let .prepare(status): return "could not prepare H.264 encoder (\(status))"
    case let .transfer(status): return "BGRA to NV12 conversion failed (\(status))"
    case let .encode(status): return "H.264 frame submission failed (\(status))"
    }
  }
}

final class VideoEncoder: @unchecked Sendable {
  let queue = DispatchQueue(label: "com.simbeam.control.video", qos: .userInteractive)
  private let orientationQueue = DispatchQueue(
    label: "com.simbeam.control.orientation", qos: .utility)

  private let output = FramedOutput()
  private var fps: Int
  private let keyframeIntervalSeconds: Double
  private var bitrate: Int
  private let scale: Double
  private let orientationReader: SimulatorOrientationReader
  private let dimensionsChanged: (Int, Int, Int, Int) -> Void

  private var sourceBuffer: CVPixelBuffer?
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var bgraPool: CVPixelBufferPool?
  private var transferSession: VTPixelTransferSession?
  private var nv12Pool: CVPixelBufferPool?
  private var compressionSession: VTCompressionSession?
  private var cadenceTimer: DispatchSourceTimer?
  private var orientationTimer: DispatchSourceTimer?
  private var orientation = SimulatorOrientation.portrait
  private var forceNextKeyframe = true
  private var outputWidth = 0
  private var outputHeight = 0
  private var stopped = false

  init(
    fps: Int,
    keyframeIntervalMilliseconds: Int,
    bitrate: Int,
    scale: Double,
    udid: UUID,
    dimensionsChanged: @escaping (Int, Int, Int, Int) -> Void
  ) {
    self.fps = fps
    self.keyframeIntervalSeconds = Double(keyframeIntervalMilliseconds) / 1000
    self.bitrate = bitrate
    self.scale = scale
    self.orientationReader = SimulatorOrientationReader(udid: udid)
    self.dimensionsChanged = dimensionsChanged
  }

  func start(surface: IOSurface) throws {
    try queue.sync {
      orientation = orientationReader.current()
      try mount(surface: surface)
      installOrientationTimer()
    }
  }

  func accept(surface: IOSurface) {
    queue.async { [weak self] in
      guard let self, !self.stopped else { return }
      do {
        try self.mount(surface: surface)
      } catch {
        Log.message("surface mount failed: \(error.localizedDescription)")
      }
    }
  }

  func requestKeyframe() {
    queue.async { [weak self] in self?.forceNextKeyframe = true }
  }

  func setBitrate(_ bitrate: Int) {
    guard bitrate > 0 else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.bitrate = bitrate
      if let session = self.compressionSession {
        let status = VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_AverageBitRate,
          value: bitrate as CFNumber)
        if status != noErr { Log.message("live bitrate update failed: \(status)") }
      }
    }
  }

  func setFPS(_ fps: Int) {
    guard fps > 0 else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.fps = fps
      self.installCadenceTimer()
      if let session = self.compressionSession {
        _ = VTSessionSetProperty(
          session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
          value: fps as CFNumber)
      }
    }
  }

  func stop() {
    queue.sync {
      stopped = true
      cadenceTimer?.cancel()
      cadenceTimer = nil
      orientationTimer?.cancel()
      orientationTimer = nil
      tearDownSession()
      sourceBuffer = nil
    }
    output.finish()
  }

  private func mount(surface: IOSurface) throws {
    var unmanagedBuffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanagedBuffer)
    guard status == kCVReturnSuccess else { throw VideoEncoderError.pixelBuffer(status) }
    guard let buffer = unmanagedBuffer?.takeRetainedValue() else {
      throw VideoEncoderError.missingPixelBuffer
    }

    sourceBuffer = buffer
    try configureForCurrentGeometry(forceNotification: false)
  }

  private func configureForCurrentGeometry(forceNotification: Bool) throws {
    guard let sourceBuffer else { return }
    let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
    let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
    let renderOrientation = effectiveImageOrientation(
      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let swapsDimensions = renderOrientation == .left || renderOrientation == .right
    let orientedSourceWidth = swapsDimensions ? sourceHeight : sourceWidth
    let orientedSourceHeight = swapsDimensions ? sourceWidth : sourceHeight
    let width = Self.evenDimension(Int(floor(Double(orientedSourceWidth) * scale)))
    let height = Self.evenDimension(Int(floor(Double(orientedSourceHeight) * scale)))

    if compressionSession == nil || width != outputWidth || height != outputHeight {
      tearDownSession()
      try setupSession(width: width, height: height)
      outputWidth = width
      outputHeight = height
      forceNextKeyframe = true
      dimensionsChanged(orientedSourceWidth, orientedSourceHeight, width, height)
      Log.message("H.264 encoder ready: \(width)x\(height) @ \(fps) fps, \(bitrate) bps")
      installCadenceTimer()
    } else if forceNotification {
      forceNextKeyframe = true
      dimensionsChanged(orientedSourceWidth, orientedSourceHeight, width, height)
    }
  }

  private func setupSession(width: Int, height: Int) throws {
    var transfer: VTPixelTransferSession?
    let transferStatus = VTPixelTransferSessionCreate(
      allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    guard transferStatus == noErr, let transfer else {
      throw VideoEncoderError.transferSession(transferStatus)
    }
    transferSession = transfer

    let bgraAttributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var bgraPool: CVPixelBufferPool?
    let bgraPoolStatus = CVPixelBufferPoolCreate(
      nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
      bgraAttributes as CFDictionary, &bgraPool)
    guard bgraPoolStatus == kCVReturnSuccess, let bgraPool else {
      throw VideoEncoderError.pixelBufferPool
    }
    self.bgraPool = bgraPool

    let pixelAttributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var pool: CVPixelBufferPool?
    let poolStatus = CVPixelBufferPoolCreate(
      nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
      pixelAttributes as CFDictionary, &pool)
    guard poolStatus == kCVReturnSuccess, let pool else { throw VideoEncoderError.pixelBufferPool }
    nv12Pool = pool

    let encoderSpecification: [String: Any] = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
      kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
    ]
    var session: VTCompressionSession?
    let createStatus = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: encoderSpecification as CFDictionary,
      imageBufferAttributes: pixelAttributes as CFDictionary,
      compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
      compressionSessionOut: &session)
    guard createStatus == noErr, let session else {
      throw VideoEncoderError.compressionSession(createStatus)
    }

    let properties: [String: Any] = [
      kVTCompressionPropertyKey_RealTime as String: true,
      kVTCompressionPropertyKey_AllowFrameReordering as String: false,
      kVTCompressionPropertyKey_MaxFrameDelayCount as String: 0,
      kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
      kVTCompressionPropertyKey_H264EntropyMode as String: kVTH264EntropyMode_CAVLC,
      kVTCompressionPropertyKey_AverageBitRate as String: bitrate,
      kVTCompressionPropertyKey_ExpectedFrameRate as String: fps,
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: keyframeIntervalSeconds,
      kVTCompressionPropertyKey_MaxKeyFrameInterval as String:
        max(1, Int(ceil(Double(fps) * keyframeIntervalSeconds))),
    ]
    let propertyStatus = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
    guard propertyStatus == noErr else {
      VTCompressionSessionInvalidate(session)
      throw VideoEncoderError.compressionProperties(propertyStatus)
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
      VTCompressionSessionInvalidate(session)
      throw VideoEncoderError.prepare(prepareStatus)
    }
    compressionSession = session
  }

  private func installCadenceTimer() {
    cadenceTimer?.cancel()
    guard compressionSession != nil, !stopped else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let interval = DispatchTimeInterval.nanoseconds(max(1, 1_000_000_000 / fps))
    timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      do {
        try self?.encodeCurrentFrame()
      } catch {
        Log.message("frame encode failed: \(error.localizedDescription)")
      }
    }
    cadenceTimer = timer
    timer.resume()
  }

  private func installOrientationTimer() {
    orientationTimer?.cancel()
    guard !stopped else { return }
    let timer = DispatchSource.makeTimerSource(queue: orientationQueue)
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let nextOrientation = self.orientationReader.current()
      self.queue.async { [weak self] in
        guard let self, !self.stopped, nextOrientation != self.orientation else { return }
        self.orientation = nextOrientation
        do {
          try self.configureForCurrentGeometry(forceNotification: true)
          Log.message("Simulator orientation changed: \(nextOrientation.rawValue)")
        } catch {
          Log.message("orientation update failed: \(error.localizedDescription)")
        }
      }
    }
    orientationTimer = timer
    timer.resume()
  }

  private func encodeCurrentFrame() throws {
    guard let sourceBuffer, let transferSession, let bgraPool, let pool = nv12Pool,
          let compressionSession else { return }

    let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
    let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
    let imageOrientation = effectiveImageOrientation(
      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let transferSource: CVPixelBuffer
    if imageOrientation == .up {
      transferSource = sourceBuffer
    } else {
      var orientedBuffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, bgraPool, &orientedBuffer) == kCVReturnSuccess,
            let orientedBuffer else { throw VideoEncoderError.pixelBufferPool }
      let image = CIImage(cvPixelBuffer: sourceBuffer).oriented(imageOrientation)
      let scaleX = CGFloat(outputWidth) / image.extent.width
      let scaleY = CGFloat(outputHeight) / image.extent.height
      let rendered = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
      imageContext.render(
        rendered, to: orientedBuffer,
        bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
        colorSpace: CGColorSpaceCreateDeviceRGB())
      transferSource = orientedBuffer
    }

    var destination: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
          let destination else { throw VideoEncoderError.pixelBufferPool }
    let transferStatus = VTPixelTransferSessionTransferImage(
      transferSession, from: transferSource, to: destination)
    guard transferStatus == noErr else { throw VideoEncoderError.transfer(transferStatus) }

    let nowMicroseconds = DispatchTime.now().uptimeNanoseconds / 1_000
    let presentationTime = CMTime(value: Int64(nowMicroseconds), timescale: 1_000_000)
    let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
    let force = forceNextKeyframe
    forceNextKeyframe = false
    let frameProperties: CFDictionary? = force
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
      : nil

    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let status = VTCompressionSessionEncodeFrame(
      compressionSession, imageBuffer: destination,
      presentationTimeStamp: presentationTime, duration: duration,
      frameProperties: frameProperties, infoFlagsOut: nil
    ) { [weak self] status, flags, sampleBuffer in
      guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
        if status != noErr { Log.message("VideoToolbox callback failed: \(status)") }
        return
      }
      do {
        let accessUnit = try AnnexBAccessUnit(sampleBuffer: sampleBuffer)
        let sampleTime = CMTimeConvertScale(
          CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
          timescale: 1_000_000,
          method: .default)
        let measuredPTS = UInt64(max(0, sampleTime.value))
        self?.output.write(accessUnit, ptsMicroseconds: measuredPTS)
      } catch {
        Log.message("Annex-B conversion failed: \(error.localizedDescription)")
      }
    }
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)
    guard status == noErr else {
      forceNextKeyframe = force
      throw VideoEncoderError.encode(status)
    }
  }

  private func tearDownSession() {
    if let compressionSession {
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(compressionSession)
    }
    compressionSession = nil
    if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    transferSession = nil
    bgraPool = nil
    nv12Pool = nil
  }

  private func effectiveImageOrientation(
    sourceWidth: Int, sourceHeight: Int
  ) -> CGImagePropertyOrientation {
    if orientation == .portraitUpsideDown {
      return .down
    }
    let sourceIsLandscape = sourceWidth > sourceHeight
    if sourceIsLandscape == orientation.isLandscape {
      return .up
    }
    return orientation.imageOrientation
  }

  private static func evenDimension(_ value: Int) -> Int {
    max(2, value - value % 2)
  }
}
