import Foundation

extension ObjCExceptionBridge {
  static func guarded<T>(_ body: () throws -> T) throws -> T {
    var outcome: Result<T, Error>?
    try run {
      do {
        outcome = .success(try body())
      } catch {
        outcome = .failure(error)
      }
    }
    guard let outcome else {
      throw NSError(
        domain: ObjCExceptionBridgeErrorDomain,
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Objective-C call returned no result"])
    }
    return try outcome.get()
  }
}
