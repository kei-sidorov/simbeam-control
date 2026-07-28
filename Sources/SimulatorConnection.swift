import Foundation
import IOSurface
@preconcurrency import CoreSimulator
@preconcurrency import CoreSimDeviceIO

enum SimulatorConnectionError: LocalizedError {
  case coreSimulatorUnavailable(String)
  case deviceSetUnavailable(String)
  case deviceNotFound(UUID)
  case deviceNotBooted(String)
  case displayNotReady(reason: String, timeout: TimeInterval)
  case cancelled

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
    case let .displayNotReady(reason, timeout):
      return "\(reason) within \(Int((timeout * 1000).rounded())) ms"
    case .cancelled:
      return "simulator startup was cancelled"
    }
  }
}

extension SimulatorConnectionError {
  /// The stable startup code reported to the parent. `.cancelled` has none: it
  /// is a requested stop, not a failure, and is handled before reporting.
  var startupFailure: StartupFailure? {
    switch self {
    case .coreSimulatorUnavailable, .deviceSetUnavailable:
      return .coreSimulatorUnavailable
    case .deviceNotFound:
      return .deviceNotFound
    case .deviceNotBooted:
      return .deviceNotBooted
    case .displayNotReady:
      return .displayNotReady
    case .cancelled:
      return nil
    }
  }
}

struct SimulatorDisplayInfo {
  let nativeScale: Double
  let pointWidth: Int
  let pointHeight: Int
}

/// Identifies a mounted surface well enough to drop duplicate notifications.
/// The plural CoreSimulator callback does not always carry the surface, so a
/// notification makes the connection re-read the property; without this the
/// re-read would remount the very same framebuffer on every notification.
private struct SurfaceIdentity: Equatable {
  let id: IOSurfaceID
  let width: Int
  let height: Int

  init(_ surface: IOSurface) {
    self.id = IOSurfaceGetID(surface)
    self.width = IOSurfaceGetWidth(surface)
    self.height = IOSurfaceGetHeight(surface)
  }
}

final class SimulatorConnection {
  /// Fallback re-read cadence for the cold-boot wait. CoreSimulator normally
  /// delivers a surface-change callback once the framebuffer exists, but the
  /// callback is not reliable across versions, so the wait also polls.
  private static let pollInterval: TimeInterval = 0.25

  let device: SimDevice
  let displayInfo: SimulatorDisplayInfo

  private let callbackID = UUID()
  /// Guards every mutable field below and wakes the startup wait.
  private let state = NSCondition()
  private var display: AnyObject?
  /// Whether `display` is the port that reports display class 0. A cold-booting
  /// port may not answer `state` yet, in which case the first conforming port is
  /// taken and later upgraded once the main display identifies itself.
  private var displayIsMain = false
  private var callbackQueue: DispatchQueue?
  private var surfaceHandler: ((IOSurface) -> Void)?
  private var pendingSurface: IOSurface?
  private var deliveredSurface: SurfaceIdentity?
  private var streaming = false
  private var cancelled = false
  private var detached = false

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

    self.device = device

    let nativeScale = max(1, Double(device.deviceType.mainScreenScale))
    let nativeSize = device.deviceType.mainScreenSize
    self.displayInfo = SimulatorDisplayInfo(
      nativeScale: nativeScale,
      pointWidth: Int((Double(nativeSize.width) / nativeScale).rounded()),
      pointHeight: Int((Double(nativeSize.height) / nativeScale).rounded()))
  }

  /// Resolves the display port, registers callbacks, and returns the first
  /// usable framebuffer IOSurface. A simulator that has just reported `Booted`
  /// may expose neither the port nor the surface yet, so both are awaited until
  /// `startupTimeout` expires. Surfaces delivered by the callback before the
  /// wait finishes are kept and returned instead of being forwarded to the
  /// handler; the handler only receives surfaces published after attachment.
  func attach(
    callbackQueue: DispatchQueue,
    startupTimeout: TimeInterval,
    surfaceHandler: @escaping (IOSurface) -> Void
  ) throws -> IOSurface {
    state.lock()
    self.callbackQueue = callbackQueue
    self.surfaceHandler = surfaceHandler
    state.unlock()

    do {
      let waited = try waitForSurface(timeout: startupTimeout)
      state.lock()
      let wasCancelled = cancelled
      streaming = !wasCancelled
      pendingSurface = nil
      let display = display
      state.unlock()
      guard !wasCancelled else { throw SimulatorConnectionError.cancelled }
      // One last read with the handler gate already open: a surface published
      // while the wait was finishing is picked up here, and anything published
      // after this point reaches the handler instead of being dropped.
      let surface = display.flatMap(Self.extractSurface(from:)) ?? waited
      state.lock()
      deliveredSurface = SurfaceIdentity(surface)
      state.unlock()
      return surface
    } catch {
      detach()
      throw error
    }
  }

  /// Unblocks a startup wait in progress. Safe to call from a signal source
  /// while `attach` is waiting; the wait then fails with `.cancelled`.
  func cancel() {
    state.lock()
    cancelled = true
    state.broadcast()
    state.unlock()
  }

  var isCancelled: Bool {
    state.lock()
    defer { state.unlock() }
    return cancelled
  }

  deinit {
    detach()
  }

  func detach() {
    state.lock()
    guard !detached else {
      state.unlock()
      return
    }
    detached = true
    streaming = false
    let display = display
    self.display = nil
    pendingSurface = nil
    deliveredSurface = nil
    callbackQueue = nil
    surfaceHandler = nil
    state.broadcast()
    state.unlock()

    if let display {
      Self.unregisterCallbacks(callbackID: callbackID, on: display)
    }
  }

  private func waitForSurface(timeout: TimeInterval) throws -> IOSurface {
    // Monotonic: an NTP step must not extend the deadline or expire it early.
    let deadline = DispatchTime.now() + timeout
    var announced = false

    while true {
      try throwIfStopped()

      let (existing, existingIsMain) = displaySnapshot()
      if !existingIsMain, let candidate = Self.resolveDisplay(device: device),
         existing == nil || candidate.isMain {
        adopt(candidate.display, isMain: candidate.isMain, replacing: existing)
      }

      if let display = currentDisplay() {
        if let surface = Self.extractSurface(from: display) { return surface }
        state.lock()
        let pending = pendingSurface
        state.unlock()
        if let pending { return pending }
      }

      guard DispatchTime.now() < deadline else {
        throw SimulatorConnectionError.displayNotReady(
          reason: currentDisplay() == nil
            ? "the booted simulator exposed no IOSurface-renderable display"
            : "the simulator display produced no framebuffer IOSurface",
          timeout: timeout)
      }
      if !announced {
        announced = true
        Log.json([
          "waiting": "framebuffer",
          "protocol": ControlProtocol.version,
          "timeout_ms": Int((timeout * 1000).rounded()),
        ])
      }

      state.lock()
      if pendingSurface == nil, !cancelled, !detached {
        _ = state.wait(until: Date().addingTimeInterval(Self.pollInterval))
      }
      state.unlock()
    }
  }

  private func throwIfStopped() throws {
    state.lock()
    defer { state.unlock() }
    if cancelled || detached { throw SimulatorConnectionError.cancelled }
  }

  private func currentDisplay() -> AnyObject? {
    state.lock()
    defer { state.unlock() }
    return display
  }

  private func displaySnapshot() -> (display: AnyObject?, isMain: Bool) {
    state.lock()
    defer { state.unlock() }
    return (display, displayIsMain)
  }

  /// Takes a freshly resolved descriptor as the display to stream from. Only
  /// ever runs while no surface has been produced, and only ever moves from no
  /// display to some display, or from a fallback port to the main one.
  private func adopt(_ candidate: AnyObject, isMain: Bool, replacing existing: AnyObject?) {
    if let existing, existing === candidate {
      state.lock()
      displayIsMain = isMain
      state.unlock()
      return
    }

    state.lock()
    guard !detached else {
      state.unlock()
      return
    }
    display = candidate
    displayIsMain = isMain
    state.unlock()

    if let existing {
      Self.unregisterCallbacks(callbackID: callbackID, on: existing)
    }
    registerCallbacks(on: candidate)
  }

  /// Called on a CoreSimulator callback thread. Before attachment completes the
  /// surface only wakes the startup wait; afterwards it is forwarded to the
  /// encoder on its own queue.
  private func deliver(_ surface: IOSurface) {
    state.lock()
    guard !detached else {
      state.unlock()
      return
    }
    guard streaming else {
      pendingSurface = surface
      state.broadcast()
      state.unlock()
      return
    }
    let identity = SurfaceIdentity(surface)
    guard identity != deliveredSurface else {
      state.unlock()
      return
    }
    deliveredSurface = identity
    let callbackQueue = callbackQueue
    let surfaceHandler = surfaceHandler
    state.unlock()
    callbackQueue?.async { surfaceHandler?(surface) }
  }

  private func registerCallbacks(on display: AnyObject) {
    guard let renderable = display as? SimDisplayIOSurfaceRenderable else { return }
    let callbackID = callbackID
    // The plural callback does not always carry the surface itself, so any
    // notification is also treated as a signal to re-read the properties.
    let callback: (Any?) -> Void = { [weak self] value in
      guard let self else { return }
      guard let surface = (value as? IOSurface)
        ?? self.currentDisplay().flatMap(Self.extractSurface(from:)) else { return }
      self.deliver(surface)
    }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.registerCallback(with: callbackID, ioSurfacesChangeCallback: callback)
    }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.registerCallback(with: callbackID, ioSurfaceChangeCallback: callback)
    }

    // A detach that raced this registration unregistered nothing, because the
    // display was not published yet; undo it here instead of leaking callbacks.
    state.lock()
    let detached = detached
    state.unlock()
    if detached {
      Self.unregisterCallbacks(callbackID: callbackID, on: display)
    }
  }

  private static func unregisterCallbacks(callbackID: UUID, on display: AnyObject) {
    guard let renderable = display as? SimDisplayIOSurfaceRenderable else { return }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.unregisterIOSurfacesChangeCallback(with: callbackID)
    }
    _ = try? ObjCExceptionBridge.guarded {
      renderable.unregisterIOSurfaceChangeCallback(with: callbackID)
    }
  }

  private static func resolveDisplay(device: SimDevice) -> (display: AnyObject, isMain: Bool)? {
    guard let ports = try? ObjCExceptionBridge.guarded({ device.io?.ioPorts() }) else {
      return nil
    }
    var fallback: AnyObject?
    for port in ports {
      let descriptor = port.descriptor as AnyObject
      guard descriptor.conforms(to: SimDisplayRenderable.self),
            descriptor.conforms(to: SimDisplayIOSurfaceRenderable.self) else {
        continue
      }
      fallback = fallback ?? descriptor
      if displayClass(of: descriptor) == 0 {
        return (descriptor, true)
      }
    }
    return fallback.map { ($0, false) }
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
