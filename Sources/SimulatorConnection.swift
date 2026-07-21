import Foundation
import IOSurface
@preconcurrency import CoreSimulator
@preconcurrency import CoreSimDeviceIO

enum SimulatorConnectionError: LocalizedError {
  case coreSimulatorUnavailable(String)
  case deviceSetUnavailable(String)
  case deviceNotFound(UUID)
  case deviceNotBooted(String)
  case noDeviceIO
  case noDisplay
  case noSurface

  var errorDescription: String? {
    switch self {
    case let .coreSimulatorUnavailable(reason):
      return "CoreSimulator is unavailable: \(reason)"
    case let .deviceSetUnavailable(reason):
      return "the default simulator device set is unavailable: \(reason)"
    case let .deviceNotFound(udid):
      return "simulator \(udid.uuidString) was not found"
    case let .deviceNotBooted(state):
      return "simulator is not booted (state: \(state))"
    case .noDeviceIO:
      return "the booted simulator has no device IO client"
    case .noDisplay:
      return "the booted simulator has no IOSurface-renderable display"
    case .noSurface:
      return "the simulator display has no framebuffer IOSurface"
    }
  }
}

struct SimulatorDisplayInfo {
  let nativeScale: Double
  let pointWidth: Int
  let pointHeight: Int
}

final class SimulatorConnection {
  let device: SimDevice
  private let display: AnyObject
  private let callbackID = UUID()
  private var callbackQueue: DispatchQueue?
  private var surfaceHandler: ((IOSurface) -> Void)?
  private var detached = false

  let displayInfo: SimulatorDisplayInfo

  init(
    udid: UUID,
    developerDirectory: String
  ) throws {
    var serviceError: AnyObject?
    guard let context = SimServiceContext.sharedServiceContext(
      forDeveloperDir: developerDirectory, error: &serviceError) as? SimServiceContext else {
      throw SimulatorConnectionError.coreSimulatorUnavailable(
        (serviceError as? NSError)?.localizedDescription ?? "unknown error")
    }

    var setError: AnyObject?
    guard let deviceSet = context.defaultDeviceSetWithError(&setError) as? SimDeviceSet else {
      throw SimulatorConnectionError.deviceSetUnavailable(
        (setError as? NSError)?.localizedDescription ?? "unknown error")
    }
    guard let device = (deviceSet.devices as? [SimDevice])?.first(where: { $0.udid == udid }) else {
      throw SimulatorConnectionError.deviceNotFound(udid)
    }
    let state = device.stateString() ?? "unknown"
    guard state == "Booted" else {
      throw SimulatorConnectionError.deviceNotBooted(state)
    }
    guard let io = device.io, let ports = io.ioPorts() else {
      throw SimulatorConnectionError.noDeviceIO
    }

    var fallback: AnyObject?
    var mainDisplay: AnyObject?
    for port in ports {
      let descriptor = port.descriptor as AnyObject
      guard descriptor.conforms(to: SimDisplayRenderable.self),
            descriptor.conforms(to: SimDisplayIOSurfaceRenderable.self) else {
        continue
      }
      fallback = fallback ?? descriptor
      if Self.displayClass(of: descriptor) == 0 {
        mainDisplay = descriptor
        break
      }
    }
    guard let display = mainDisplay ?? fallback else {
      throw SimulatorConnectionError.noDisplay
    }

    self.device = device
    self.display = display

    let nativeScale = max(1, Double(device.deviceType.mainScreenScale))
    let nativeSize = device.deviceType.mainScreenSize
    self.displayInfo = SimulatorDisplayInfo(
      nativeScale: nativeScale,
      pointWidth: Int((Double(nativeSize.width) / nativeScale).rounded()),
      pointHeight: Int((Double(nativeSize.height) / nativeScale).rounded()))

  }

  func attach(
    callbackQueue: DispatchQueue,
    surfaceHandler: @escaping (IOSurface) -> Void
  ) throws -> IOSurface {
    self.callbackQueue = callbackQueue
    self.surfaceHandler = surfaceHandler
    detached = false
    try registerCallbacks()
    guard let surface = Self.extractSurface(from: display) else {
      detach()
      throw SimulatorConnectionError.noSurface
    }
    return surface
  }

  deinit {
    detach()
  }

  func detach() {
    guard !detached else { return }
    detached = true
    let callbackID = callbackID
    if let renderable = display as? SimDisplayIOSurfaceRenderable {
      _ = try? ObjCExceptionBridge.guarded {
        renderable.unregisterIOSurfacesChangeCallback(with: callbackID)
      }
      _ = try? ObjCExceptionBridge.guarded {
        renderable.unregisterIOSurfaceChangeCallback(with: callbackID)
      }
    }
    callbackQueue = nil
    surfaceHandler = nil
  }

  private func registerCallbacks() throws {
    guard let renderable = display as? SimDisplayIOSurfaceRenderable else {
      throw SimulatorConnectionError.noDisplay
    }
    let callbackID = callbackID
    guard let callbackQueue, let surfaceHandler else {
      throw SimulatorConnectionError.noDisplay
    }
    let callback: (Any?) -> Void = { value in
      guard let surface = value as? IOSurface else { return }
      callbackQueue.async {
        surfaceHandler(surface)
      }
    }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.registerCallback(with: callbackID, ioSurfacesChangeCallback: callback)
    }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.registerCallback(with: callbackID, ioSurfaceChangeCallback: callback)
    }
  }

  private static func displayClass(of descriptor: AnyObject) -> UInt16? {
    guard descriptor.responds(to: NSSelectorFromString("state")) else { return nil }
    return try? ObjCExceptionBridge.guarded {
      let state = descriptor.perform(NSSelectorFromString("state"))?.takeUnretainedValue()
      return (state as? SimDisplayDescriptorState)?.displayClass
    }
  }

  private static func extractSurface(from display: AnyObject) -> IOSurface? {
    guard let renderable = display as? SimDisplayIOSurfaceRenderable else { return nil }
    if let surface = try? ObjCExceptionBridge.guarded({ renderable.framebufferSurface }) as? IOSurface {
      return surface
    }
    return try? ObjCExceptionBridge.guarded({ renderable.ioSurface }) as? IOSurface
  }
}
