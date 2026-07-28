import Foundation

enum Log {
  private static let lock = NSLock()

  static func message(_ text: String) {
    write(text + "\n")
  }

  static func json(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else {
      message("failed to serialize stderr JSON")
      return
    }
    write(text + "\n")
  }

  private static func write(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
  }
}

/// Stable startup failure codes. A helper that fails before the ready handshake
/// writes exactly one of these as a JSON line on stderr, so the parent can tell
/// a transient cold-boot condition from a permanent misconfiguration without
/// parsing prose. Codes are part of the control protocol and must not be
/// renamed or reused.
enum StartupFailure: String {
  case invalidArguments = "invalid_arguments"
  case coreSimulatorUnavailable = "core_simulator_unavailable"
  case deviceNotFound = "device_not_found"
  case deviceNotBooted = "device_not_booted"
  case displayNotReady = "display_not_ready"
  case encoderFailed = "encoder_failed"
  case hidUnavailable = "hid_unavailable"

  /// Whether the same invocation is worth retrying unchanged. Cold-boot
  /// conditions resolve on their own; a missing device or a bad argument does
  /// not.
  var isRetryable: Bool {
    switch self {
    case .deviceNotBooted, .displayNotReady:
      return true
    case .invalidArguments, .coreSimulatorUnavailable, .deviceNotFound, .encoderFailed,
         .hidUnavailable:
      return false
    }
  }

  func report(_ message: String) {
    Log.json([
      "ready": false,
      "protocol": ControlProtocol.version,
      "error": rawValue,
      "message": message,
      "retryable": isRetryable,
    ])
  }

  func report(_ error: Error) {
    report(error.localizedDescription)
  }
}
