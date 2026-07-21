import Foundation

final class FramedOutput {
  private let queue = DispatchQueue(label: "com.simbeam.control.stdout")
  private var failed = false

  func write(_ accessUnit: AnnexBAccessUnit, ptsMicroseconds: UInt64) {
    var packet = Data(capacity: 13 + accessUnit.data.count)
    var length = UInt32(accessUnit.data.count).bigEndian
    withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
    packet.append(accessUnit.isKeyframe ? 1 : 0)
    var pts = ptsMicroseconds.bigEndian
    withUnsafeBytes(of: &pts) { packet.append(contentsOf: $0) }
    packet.append(accessUnit.data)

    queue.async { [weak self] in
      guard let self, !self.failed else { return }
      do {
        try FileHandle.standardOutput.write(contentsOf: packet)
      } catch {
        self.failed = true
        Log.message("stdout write failed: \(error.localizedDescription)")
      }
    }
  }

  func finish() {
    queue.sync {}
  }
}
