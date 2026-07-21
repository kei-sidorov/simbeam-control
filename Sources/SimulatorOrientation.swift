import CoreFoundation
import Foundation
import ImageIO

enum SimulatorOrientation: String {
  case portrait = "Portrait"
  case portraitUpsideDown = "PortraitUpsideDown"
  case landscapeLeft = "LandscapeLeft"
  case landscapeRight = "LandscapeRight"

  var isLandscape: Bool {
    self == .landscapeLeft || self == .landscapeRight
  }

  var imageOrientation: CGImagePropertyOrientation {
    switch self {
    case .portrait: return .up
    case .portraitUpsideDown: return .down
    case .landscapeLeft: return .left
    case .landscapeRight: return .right
    }
  }
}

struct SimulatorOrientationReader: Sendable {
  private static let preferencesDomain = "com.apple.iphonesimulator" as CFString
  private let udid: String

  init(udid: UUID) {
    self.udid = udid.uuidString
  }

  func current() -> SimulatorOrientation {
    CFPreferencesAppSynchronize(Self.preferencesDomain)
    guard
      let preferences = CFPreferencesCopyAppValue(
        "DevicePreferences" as CFString, Self.preferencesDomain) as? [String: Any],
      let devicePreferences = preferences[udid] as? [String: Any]
    else {
      return .portrait
    }

    if let name = devicePreferences["SimulatorWindowOrientation"] as? String,
       let orientation = SimulatorOrientation(rawValue: name) {
      return orientation
    }

    let angle = (devicePreferences["SimulatorWindowRotationAngle"] as? NSNumber)?.doubleValue ?? 0
    let normalizedAngle = (angle.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    switch normalizedAngle {
    case 45..<135: return .landscapeLeft
    case 135..<225: return .portraitUpsideDown
    case 225..<315: return .landscapeRight
    default: return .portrait
    }
  }
}
