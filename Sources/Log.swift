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
