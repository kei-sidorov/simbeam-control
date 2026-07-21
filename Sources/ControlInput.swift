import Foundation

final class ControlInput {
  private var buffer = Data()
  private let encoder: VideoEncoder
  private let hid: HIDController
  private let eof: () -> Void

  init(encoder: VideoEncoder, hid: HIDController, eof: @escaping () -> Void) {
    self.encoder = encoder
    self.hid = hid
    self.eof = eof
  }

  func start() {
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        self.eof()
        return
      }
      self.consume(data)
    }
  }

  private func consume(_ data: Data) {
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[..<newline]
      buffer.removeSubrange(...newline)
      handle(line: Data(line))
    }
  }

  private func handle(line: Data) {
    guard !line.isEmpty else { return }
    do {
      guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String else {
        throw ControlError.invalidCommand
      }
      switch type {
      case "keyframe":
        encoder.requestKeyframe()
      case "quality":
        if let bitrate = object["bitrate"] as? Int { encoder.setBitrate(bitrate) }
        if let fps = object["fps"] as? Int { encoder.setFPS(fps) }
      case "tap":
        guard let x = number(object["x"]), let y = number(object["y"]) else {
          throw ControlError.invalidCommand
        }
        hid.tap(x: x, y: y)
      case "swipe":
        guard let x1 = number(object["x1"]), let y1 = number(object["y1"]),
              let x2 = number(object["x2"]), let y2 = number(object["y2"]),
              let duration = object["duration_ms"] as? Int else {
          throw ControlError.invalidCommand
        }
        hid.swipe(
          x1: x1, y1: y1, x2: x2, y2: y2,
          durationMilliseconds: duration)
      case "shake":
        hid.shake()
      case "home":
        hid.home()
      case "key":
        guard let usage = object["usage"] as? Int, usage >= 0 else {
          throw ControlError.invalidCommand
        }
        let shift = (object["shift"] as? Bool) ?? false
        hid.key(usage: UInt32(usage), shift: shift)
      default:
        throw ControlError.unsupported(type)
      }
    } catch {
      Log.message("invalid control line: \(error.localizedDescription)")
    }
  }

  private func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }
}

enum ControlError: LocalizedError {
  case invalidCommand
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .invalidCommand: return "expected a JSON object with a string 'type'"
    case let .unsupported(type): return "unsupported command type '\(type)'"
    }
  }
}
