import CoreMedia
import Foundation

enum AnnexBError: LocalizedError {
  case sampleNotReady
  case missingData
  case missingFormat
  case parameterSet(OSStatus)
  case malformedNALUnits
  case copyFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .sampleNotReady: return "encoded sample is not ready"
    case .missingData: return "encoded sample has no data buffer"
    case .missingFormat: return "encoded sample has no format description"
    case let .parameterSet(status): return "could not read H.264 parameter sets (\(status))"
    case .malformedNALUnits: return "encoded sample contains malformed AVCC NAL units"
    case let .copyFailed(status): return "could not copy encoded sample bytes (\(status))"
    }
  }
}

struct AnnexBAccessUnit {
  let data: Data
  let isKeyframe: Bool

  init(sampleBuffer: CMSampleBuffer) throws {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { throw AnnexBError.sampleNotReady }
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw AnnexBError.missingData }

    isKeyframe = Self.isKeyframe(sampleBuffer)
    var output = Data()
    var nalHeaderLength: Int32 = 4

    if isKeyframe {
      guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw AnnexBError.missingFormat
      }
      var parameterSetCount = 0
      let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0, parameterSetPointerOut: nil,
        parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalHeaderLength)
      guard countStatus == noErr else { throw AnnexBError.parameterSet(countStatus) }
      for index in 0..<parameterSetCount {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size, parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else { throw AnnexBError.parameterSet(status) }
        output.append(contentsOf: [0, 0, 0, 1])
        output.append(pointer, count: size)
      }
    }

    let byteCount = CMBlockBufferGetDataLength(blockBuffer)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let copyStatus = bytes.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
    }
    guard copyStatus == noErr else { throw AnnexBError.copyFailed(copyStatus) }

    let headerSize = Int(nalHeaderLength)
    guard headerSize > 0, headerSize <= 4 else { throw AnnexBError.malformedNALUnits }
    var offset = 0
    while offset < bytes.count {
      guard offset + headerSize <= bytes.count else { throw AnnexBError.malformedNALUnits }
      var nalSize = 0
      for byte in bytes[offset..<(offset + headerSize)] {
        nalSize = (nalSize << 8) | Int(byte)
      }
      offset += headerSize
      guard nalSize > 0, offset + nalSize <= bytes.count else {
        throw AnnexBError.malformedNALUnits
      }
      output.append(contentsOf: [0, 0, 0, 1])
      output.append(contentsOf: bytes[offset..<(offset + nalSize)])
      offset += nalSize
    }

    data = output
  }

  private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 else {
      return false
    }
    let attachment = unsafeBitCast(
      CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
    return !CFDictionaryContainsKey(
      attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
  }
}
