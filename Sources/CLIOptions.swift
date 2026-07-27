import Foundation

/// The control protocol version this binary speaks, printed by `--protocol` and
/// carried in the ready handshake. The daemon preflights `--protocol` and
/// refuses to run against a helper older than its required minimum; a binary
/// that predates the flag exits non-zero and is treated as version 1.
///
/// History:
///   1 — tap/swipe/home/key/shake/keyframe/quality commands, framed H.264
///       stdout, stderr ready handshake.
///   2 — streamed touch (down/move/up) and app_switcher.
enum ControlProtocol {
  static let version = 2
}

struct CLIOptions {
  let udid: UUID
  let fps: Int
  let keyframeIntervalMilliseconds: Int
  let bitrate: Int
  let scale: Double

  static let usage = """
  Usage: simbeam-control --udid <UDID> [--fps 30] [--keyframe-interval-ms 2000]
                         [--bitrate 4000000] [--scale 1.0]
         simbeam-control --protocol    print the control protocol version and exit
  """

  static func parse(_ arguments: [String]) throws -> CLIOptions {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--help" || argument == "-h" {
        throw CLIError.help
      }
      if argument == "--protocol" {
        throw CLIError.protocolQuery
      }
      guard argument.hasPrefix("--"), index + 1 < arguments.count else {
        throw CLIError.invalidArgument(argument)
      }
      values[argument] = arguments[index + 1]
      index += 2
    }

    guard let rawUDID = values["--udid"], let udid = UUID(uuidString: rawUDID) else {
      throw CLIError.missingUDID
    }
    let fps = try positiveInt(values["--fps"] ?? "30", name: "--fps")
    let keyframeInterval = try positiveInt(
      values["--keyframe-interval-ms"] ?? "2000", name: "--keyframe-interval-ms")
    let bitrate = try positiveInt(values["--bitrate"] ?? "4000000", name: "--bitrate")
    guard let scale = Double(values["--scale"] ?? "1.0"), scale > 0, scale <= 1 else {
      throw CLIError.invalidValue("--scale must be in (0, 1]")
    }

    let supported = Set(["--udid", "--fps", "--keyframe-interval-ms", "--bitrate", "--scale"])
    if let unknown = values.keys.first(where: { !supported.contains($0) }) {
      throw CLIError.invalidArgument(unknown)
    }

    return CLIOptions(
      udid: udid,
      fps: fps,
      keyframeIntervalMilliseconds: keyframeInterval,
      bitrate: bitrate,
      scale: scale)
  }

  private static func positiveInt(_ value: String, name: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
      throw CLIError.invalidValue("\(name) must be a positive integer")
    }
    return parsed
  }
}

enum CLIError: LocalizedError {
  case help
  case protocolQuery
  case missingUDID
  case invalidArgument(String)
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .help, .protocolQuery:
      return nil
    case .missingUDID:
      return "--udid is required and must be a UUID"
    case let .invalidArgument(argument):
      return "invalid argument: \(argument)"
    case let .invalidValue(message):
      return message
    }
  }
}
