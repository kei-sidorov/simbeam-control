/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import XPC
@preconcurrency import CoreSimulator
import SimulatorApp

enum HIDError: LocalizedError {
  case simulatorKitUnavailable(String)
  case symbolUnavailable(String)
  case clientClassUnavailable
  case clientCreationFailed(String)
  case modernClientNotReady
  case disconnected
  case invalidCoordinate
  case shakeFailed(Int32)

  var errorDescription: String? {
    switch self {
    case let .simulatorKitUnavailable(reason): return "SimulatorKit is unavailable: \(reason)"
    case let .symbolUnavailable(symbol): return "SimulatorKit does not export \(symbol)"
    case .clientClassUnavailable: return "SimulatorKit.SimDeviceLegacyHIDClient is unavailable"
    case let .clientCreationFailed(reason): return "could not create the simulator HID client: \(reason)"
    case .modernClientNotReady: return "DTUHID did not answer the input probe before the startup deadline"
    case .disconnected: return "the simulator HID client is disconnected"
    case .invalidCoordinate: return "touch coordinates must be finite and inside the simulator point space"
    case let .shakeFailed(status): return "simctl shake notification failed with exit status \(status)"
    }
  }
}

private enum TouchDirection: Int32 {
  case down = 1
  case up = 2
}

@objc private protocol SimDeviceLegacyHIDClientMessaging {
  @objc(initWithDevice:error:)
  func initWithDevice(
    _ device: Any,
    error: AutoreleasingUnsafeMutablePointer<AnyObject?>?
  ) -> AnyObject?

  @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
  func send(
    withMessage message: UnsafeMutableRawPointer,
    freeWhenDone: Bool,
    completionQueue: DispatchQueue,
    completion: @escaping @Sendable (Error?) -> Void)
}

final class HIDController: @unchecked Sendable {
  private typealias MouseMessageBuilder = @convention(c) (
    UnsafeMutablePointer<CGPoint>?,
    UnsafeMutablePointer<CGPoint>?,
    Int32,
    Int32,
    ObjCBool
  ) -> UnsafeMutablePointer<IndigoMessage>

  // queue runs one gesture at a time to completion, so concurrent taps never
  // overlap into a multi-finger touch; completionQueue receives the HID client's
  // async delivery callbacks so a gesture can block on `queue` waiting for them
  // without deadlocking against itself.
  private let queue = DispatchQueue(label: "com.simbeam.control.hid", qos: .userInteractive)
  private let completionQueue = DispatchQueue(label: "com.simbeam.control.hid.completion")
  private let udid: UUID
  private let pointSize: CGSize
  private let pixelSize: CGSize
  private let screenScale: Float
  private let messageBuilder: MouseMessageBuilder
  private var client: AnyObject?
  private var modernTransport: SimulatorHIDTransport?
  // last point of an in-progress streamed touch; non-nil means the finger is
  // down. Guarded by `queue`.
  private var streamedTouchPoint: CGPoint?

  init(
    device: SimDevice,
    udid: UUID,
    displayInfo: SimulatorDisplayInfo,
    developerDirectory: String,
    startupDeadline: TimeInterval
  ) throws {
    let developerURL = URL(fileURLWithPath: developerDirectory, isDirectory: true)
    let simulatorKitPaths = [
      developerURL.appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework").path,
      developerURL.deletingLastPathComponent()
        .appendingPathComponent("SharedFrameworks/SimulatorKit.framework").path,
    ]
    guard let bundle = simulatorKitPaths.compactMap({ Bundle(path: $0) }).first else {
      throw HIDError.simulatorKitUnavailable("not found at \(simulatorKitPaths.joined(separator: ", "))")
    }
    if !bundle.isLoaded {
      do {
        try bundle.loadAndReturnError()
      } catch {
        throw HIDError.simulatorKitUnavailable(error.localizedDescription)
      }
    }
    guard let executablePath = bundle.executablePath,
          let handle = dlopen(executablePath, RTLD_NOW | RTLD_LOCAL) else {
      let reason = dlerror().map { String(cString: $0) } ?? "framework executable is unavailable"
      throw HIDError.simulatorKitUnavailable(reason)
    }
    let symbolName = "IndigoHIDMessageForMouseNSEvent"
    guard let symbol = dlsym(handle, symbolName) else {
      throw HIDError.symbolUnavailable(symbolName)
    }
    messageBuilder = unsafeBitCast(symbol, to: MouseMessageBuilder.self)

    guard let clientClass = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient") else {
      throw HIDError.clientClassUnavailable
    }
    let allocated = class_createInstance(clientClass, 0) as AnyObject
    var clientError: AnyObject?
    guard let client = unsafeBitCast(allocated, to: SimDeviceLegacyHIDClientMessaging.self)
      .initWithDevice(device, error: &clientError) else {
      throw HIDError.clientCreationFailed(
        (clientError as? NSError)?.localizedDescription ?? String(describing: clientError))
    }

    self.client = client
    self.udid = udid
    self.pointSize = CGSize(width: displayInfo.pointWidth, height: displayInfo.pointHeight)
    self.screenScale = Float(displayInfo.nativeScale)
    self.pixelSize = CGSize(
      width: Double(displayInfo.pointWidth) * displayInfo.nativeScale,
      height: Double(displayInfo.pointHeight) * displayInfo.nativeScale)
    // Legacy Indigo delivery can succeed without actuating iOS 26/27 guests under Xcode 27.
    let simulatorKitXcode = (bundle.infoDictionary?["DTXcode"] as? String).flatMap(Int.init) ?? 0
    if device.runtimeIdentifier.contains("iOS-27-")
      || (device.runtimeIdentifier.contains("iOS-26-") && simulatorKitXcode >= 2700) {
      modernTransport = try SimulatorHIDTransport.connect(device: device, deadline: startupDeadline)
    }
  }

  func disconnect() {
    queue.sync {
      if let point = streamedTouchPoint {
        // never leave the simulator with a stuck finger when the parent goes away
        perform([ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .up, x: point.x, y: point.y))])
        streamedTouchPoint = nil
      }
      modernTransport?.drain()
      modernTransport = nil
      client = nil
    }
  }

  // touchDown / touchMove / touchUp stream one externally driven touch: the
  // parent controls the trajectory and timing, so curved swipes, long presses,
  // and drags with pauses all work. Events are delivered immediately as they
  // arrive instead of being interpolated like `swipe`.
  func touchDown(x: Double, y: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try validate(x: x, y: y)
        if let point = streamedTouchPoint {
          Log.message("touch down while a streamed touch is active; releasing the previous touch")
          perform([ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .up, x: point.x, y: point.y))])
        }
        streamedTouchPoint = CGPoint(x: x, y: y)
        perform([ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .down, x: x, y: y))])
      } catch {
        Log.message("touch down failed: \(error.localizedDescription)")
      }
    }
  }

  func touchMove(x: Double, y: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      // Silently ignored: the parent's channel is lossy, so a move outliving
      // its touch (lost down, or arriving after up) is expected traffic, not
      // an anomaly worth a log line per event.
      guard streamedTouchPoint != nil else { return }
      do {
        try validate(x: x, y: y)
        streamedTouchPoint = CGPoint(x: x, y: y)
        // Indigo has no distinct move message: a move is a down at new coordinates
        perform([ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .down, x: x, y: y))])
      } catch {
        Log.message("touch move failed: \(error.localizedDescription)")
      }
    }
  }

  func touchUp(x: Double, y: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      // Silently ignored: clients are told to send up redundantly (it is the
      // one message that matters over a lossy channel), so duplicates are the
      // designed steady state — logging each one floods the parent's console.
      guard let previous = streamedTouchPoint else { return }
      // an out-of-bounds release still lifts the finger at the last valid point
      let point = (try? validate(x: x, y: y)) != nil ? CGPoint(x: x, y: y) : previous
      streamedTouchPoint = nil
      perform([ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .up, x: point.x, y: point.y))])
    }
  }

  func tap(x: Double, y: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.streamedTouchPoint == nil else {
        Log.message("tap dropped: a streamed touch is active")
        return
      }
      do {
        try validate(x: x, y: y)
        perform([
          ScheduledTouch(delay: 0, event: HIDEvent.touch(direction: .down, x: x, y: y)),
          ScheduledTouch(delay: 0.01, event: HIDEvent.touch(direction: .up, x: x, y: y)),
        ])
      } catch {
        Log.message("tap failed: \(error.localizedDescription)")
      }
    }
  }

  func swipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMilliseconds: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.streamedTouchPoint == nil else {
        Log.message("swipe dropped: a streamed touch is active")
        return
      }
      do {
        try validate(x: x1, y: y1)
        try validate(x: x2, y: y2)
        let duration = max(0.01, Double(durationMilliseconds) / 1_000)
        let distance = hypot(x2 - x1, y2 - y1)
        let steps = max(1, Int(distance / 10))
        let stepDelay = duration / Double(steps + 2)
        var events: [ScheduledTouch] = []
        for index in 0...steps {
          let progress = Double(index) / Double(steps)
          let x = x1 + (x2 - x1) * progress
          let y = y1 + (y2 - y1) * progress
          events.append(ScheduledTouch(
            delay: stepDelay,
            event: HIDEvent.touch(direction: .down, x: x, y: y)))
        }
        events.append(ScheduledTouch(
          delay: stepDelay,
          event: HIDEvent.touch(direction: .down, x: x2, y: y2)))
        events.append(ScheduledTouch(
          delay: 0,
          event: HIDEvent.touch(direction: .up, x: x2, y: y2)))
        perform(events)
      } catch {
        Log.message("swipe failed: \(error.localizedDescription)")
      }
    }
  }

  func home() {
    queue.async { [weak self] in
      guard let self else { return }
      self.perform([
        ScheduledTouch(delay: 0, event: HIDEvent.button(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeDown), keyCode: 0)),
        ScheduledTouch(delay: self.modernTransport == nil ? 0.01 : 0.05, event: HIDEvent.button(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeUp), keyCode: 0)),
      ])
    }
  }

  // appSwitcher opens the running-apps switcher via a double Home press. Both
  // presses run inside one serialized gesture so nothing can interleave between
  // them and break the double-press timing window.
  func appSwitcher() {
    queue.async { [weak self] in
      guard let self else { return }
      var events: [ScheduledTouch] = []
      for press in 0..<2 {
        events.append(ScheduledTouch(delay: press == 0 ? 0 : 0.05, event: HIDEvent.button(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeDown), keyCode: 0)))
        events.append(ScheduledTouch(delay: self.modernTransport == nil ? 0.01 : 0.05, event: HIDEvent.button(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeUp), keyCode: 0)))
      }
      self.perform(events)
    }
  }

  // key presses and releases a USB HID keyboard usage code (page 0x07). When
  // shift is set, left-shift (usage 225) is held around the key. Usage/shift are
  // resolved by the caller from the browser KeyboardEvent.key, so the simulator's
  // active hardware layout selects the glyph — the same known limitation idb had.
  func key(usage: UInt32, shift: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      let shiftUsage: UInt32 = 225
      var events: [ScheduledTouch] = []
      if shift {
        events.append(ScheduledTouch(delay: 0, event: keyEvent(usage: shiftUsage, direction: UInt32(ButtonEventTypeDown))))
      }
      events.append(ScheduledTouch(delay: 0, event: keyEvent(usage: usage, direction: UInt32(ButtonEventTypeDown))))
      events.append(ScheduledTouch(delay: 0.01, event: keyEvent(usage: usage, direction: UInt32(ButtonEventTypeUp))))
      if shift {
        events.append(ScheduledTouch(delay: 0, event: keyEvent(usage: shiftUsage, direction: UInt32(ButtonEventTypeUp))))
      }
      self.perform(events)
    }
  }

  func shake() {
    queue.async { [udid] in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = [
        "simctl", "spawn", udid.uuidString,
        "notifyutil", "-p", "com.apple.UIKit.SimulatorShake",
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
          throw HIDError.shakeFailed(process.terminationStatus)
        }
      } catch {
        Log.message("shake failed: \(error.localizedDescription)")
      }
    }
  }

  private func validate(x: Double, y: Double) throws {
    guard x.isFinite, y.isFinite,
          x >= 0, y >= 0, x <= pointSize.width, y <= pointSize.height else {
      throw HIDError.invalidCoordinate
    }
  }

  private func legacyTouchData(direction: TouchDirection, x: Double, y: Double) -> Data {
    var point = CGPoint(
      x: (x * Double(screenScale)) / pixelSize.width,
      y: (y * Double(screenScale)) / pixelSize.height)
    let source = messageBuilder(
      &point, nil, 0x32, direction.rawValue, ObjCBool(false))
    source.pointee.payload.event.touch.xRatio = point.x
    source.pointee.payload.event.touch.yRatio = point.y
    let sourceBytes = UnsafeMutableRawPointer(source)

    let payloadStride = MemoryLayout<IndigoPayload>.size
    let messageSize = MemoryLayout<IndigoMessage>.size + payloadStride
    guard let destination = calloc(1, messageSize) else {
      fatalError("failed to allocate an Indigo touch message")
    }
    let message = destination.assumingMemoryBound(to: IndigoMessage.self)
    message.pointee.innerSize = UInt32(payloadStride)
    message.pointee.eventType = UInt8(IndigoEventTypeTouch)
    message.pointee.payload.eventKind = 0x0000_000B
    message.pointee.payload.timestamp = mach_absolute_time()

    memcpy(
      destination.advanced(by: 0x30),
      sourceBytes.advanced(by: 0x30),
      MemoryLayout<IndigoTouch>.size)
    free(source)

    memcpy(
      destination.advanced(by: 0x20 + payloadStride),
      destination.advanced(by: 0x20),
      payloadStride)
    let secondPayload = destination.advanced(by: 0x20 + payloadStride)
      .assumingMemoryBound(to: IndigoPayload.self)
    secondPayload.pointee.event.touch.field1 = 1
    secondPayload.pointee.event.touch.field2 = 2

    return Data(bytesNoCopy: destination, count: messageSize, deallocator: .free)
  }

  private func keyEvent(usage: UInt32, direction: UInt32) -> HIDEvent {
    HIDEvent.button(
      source: UInt32(ButtonEventSourceKeyboard),
      target: UInt32(ButtonEventTargetKeyboard),
      direction: direction, keyCode: usage)
  }

  // The mach header stays zeroed because SimDeviceLegacyHIDClient fills it on send.
  private func legacyButtonData(source: UInt32, target: UInt32, direction: UInt32, keyCode: UInt32) -> Data {
    let messageSize = MemoryLayout<IndigoMessage>.size
    guard let destination = calloc(1, messageSize) else {
      fatalError("failed to allocate an Indigo button message")
    }
    let message = destination.assumingMemoryBound(to: IndigoMessage.self)
    message.pointee.innerSize = UInt32(MemoryLayout<IndigoPayload>.size)
    message.pointee.eventType = UInt8(IndigoEventTypeButton)
    message.pointee.payload.eventKind = 2
    message.pointee.payload.timestamp = mach_absolute_time()
    message.pointee.payload.event.button.eventSource = source
    message.pointee.payload.event.button.eventType = direction
    message.pointee.payload.event.button.eventTarget = target
    message.pointee.payload.event.button.keyCode = keyCode
    return Data(bytesNoCopy: destination, count: messageSize, deallocator: .free)
  }

  // Must run on the gesture queue so contacts cannot interleave into a multi-finger touch.
  private func perform(_ events: [ScheduledTouch]) {
    for event in events {
      if event.delay > 0 {
        Thread.sleep(forTimeInterval: event.delay)
      }
      deliver(event.event)
    }
  }

  // Legacy completion runs off the gesture queue, with a deadline so a disconnected client cannot hang shutdown.
  private func deliver(_ event: HIDEvent) {
    if let modernTransport {
      switch event {
      case let .touch(direction, x, y):
        modernTransport.touch(direction: direction, x: x / pointSize.width, y: y / pointSize.height)
      case let .button(_, target, direction, keyCode):
        if target == UInt32(ButtonEventTargetKeyboard) {
          modernTransport.key(usage: UInt64(keyCode), state: UInt64(direction))
        } else {
          modernTransport.button(state: UInt64(direction))
        }
      }
      return
    }
    let data: Data
    switch event {
    case let .touch(direction, x, y):
      data = legacyTouchData(direction: direction, x: x, y: y)
    case let .button(source, target, direction, keyCode):
      data = legacyButtonData(source: source, target: target, direction: direction, keyCode: keyCode)
    }
    let done = DispatchSemaphore(value: 0)
    send(data) { error in
      if let error {
        Log.message("HID delivery failed: \(error.localizedDescription)")
      }
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1)
  }

  private func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
    guard let client else {
      completion(HIDError.disconnected)
      return
    }
    guard let raw = malloc(data.count) else {
      fatalError("failed to allocate an Indigo message copy")
    }
    data.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: data.count)
    unsafeBitCast(client, to: SimDeviceLegacyHIDClientMessaging.self).send(
      withMessage: raw,
      freeWhenDone: true,
      completionQueue: completionQueue,
      completion: completion)
  }
}

private struct ScheduledTouch {
  let delay: TimeInterval
  let event: HIDEvent
}

private enum HIDEvent {
  case touch(direction: TouchDirection, x: Double, y: Double)
  case button(source: UInt32, target: UInt32, direction: UInt32, keyCode: UInt32)
}

private final class SimulatorHIDTransport {
  private typealias MakeEndpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
  private typealias MakeConnection = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
  private typealias EnableSimulator = @convention(c) (xpc_connection_t) -> Void
  private let connection: xpc_connection_t
  private var contactActive = false
  private let replyQueue = DispatchQueue(label: "com.simbeam.control.dtuhid.reply")
  private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"

  static func connect(device: SimDevice, deadline: TimeInterval) throws -> SimulatorHIDTransport {
    for attempt in 1...5 {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw HIDError.modernClientNotReady }
      do {
        return try SimulatorHIDTransport(device: device, probeTimeout: min(4, remaining))
      } catch HIDError.modernClientNotReady {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard attempt < 5, remaining > 0 else { throw HIDError.modernClientNotReady }
        Log.message("DTUHID is not ready; retrying input connection before the startup deadline")
        Thread.sleep(forTimeInterval: min(1, remaining))
      }
    }
    throw HIDError.modernClientNotReady
  }

  private init(device: SimDevice, probeTimeout: TimeInterval) throws {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      throw HIDError.simulatorKitUnavailable("DTUHID symbols unavailable")
    }
    defer { dlclose(handle) }
    guard let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let simulatorSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
      throw HIDError.simulatorKitUnavailable("DTUHID connection symbols unavailable")
    }
    var error: NSError?
    let port = device.lookup(Self.service, error: &error)
    guard port != MACH_PORT_NULL else {
      throw error ?? NSError(domain: "com.simbeam.control.dtuhid", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "DTUHID service lookup failed"])
    }
    let makeEndpoint = unsafeBitCast(endpointSymbol, to: MakeEndpoint.self)
    let makeConnection = unsafeBitCast(connectionSymbol, to: MakeConnection.self)
    let enableSimulator = unsafeBitCast(simulatorSymbol, to: EnableSimulator.self)
    guard let endpoint = makeEndpoint(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
          let connection = makeConnection(endpoint)?.takeRetainedValue() as? xpc_connection_t else {
      throw HIDError.simulatorKitUnavailable("DTUHID connection creation failed")
    }
    self.connection = connection
    // Without sim2host mode the guest can accept the connection but never receive its messages.
    enableSimulator(connection)
    xpc_connection_set_target_queue(connection, replyQueue)
    xpc_connection_set_event_handler(connection) { event in
      if xpc_get_type(event) == XPC_TYPE_ERROR {
        let description = xpc_copy_description(event)
        defer { free(description) }
        Log.message("HID transport: \(String(cString: description))")
      }
    }
    xpc_connection_resume(connection)
    // A successful lookup can precede dtuhidd startup; require a harmless round-trip before accepting input.
    let done = DispatchSemaphore(value: 0)
    let probe = envelope(type: "IndigoKeyboardButtonEvent", barrier: true)
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(payload, "usageCode", 0)
    xpc_dictionary_set_uint64(payload, "state", 2)
    xpc_dictionary_set_value(probe, "payload", payload)
    let result = HIDProbeResult()
    xpc_connection_send_message_with_reply(connection, probe, replyQueue) { reply in
      result.ok = xpc_get_type(reply) != XPC_TYPE_ERROR
      done.signal()
    }
    guard done.wait(timeout: .now() + probeTimeout) == .success, result.ok else {
      xpc_connection_cancel(connection)
      throw HIDError.modernClientNotReady
    }
    // The liveness reply precedes the guest opening its HID device.
    Thread.sleep(forTimeInterval: 0.2)
  }

  deinit { xpc_connection_cancel(connection) }

  func touch(direction: TouchDirection, x: Double, y: Double) {
    let phase: UInt64
    switch direction {
    case .down:
      phase = contactActive ? 1 : 0
      contactActive = true
    case .up:
      phase = 2
      contactActive = false
    }
    let point = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_double(point, "x", x)
    xpc_dictionary_set_double(point, "y", y)
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(payload, "pointOne", point)
    // dtuhidd requires unsigned phases and an omitted pointTwo for single-finger input.
    xpc_dictionary_set_uint64(payload, "eventType", phase)
    xpc_dictionary_set_uint64(payload, "edge", 0)
    xpc_dictionary_set_uint64(payload, "target", 0)
    send(type: "IndigoDigitizerEvent", payload: payload)
  }

  func key(usage: UInt64, state: UInt64) {
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(payload, "usageCode", usage)
    xpc_dictionary_set_uint64(payload, "state", state)
    send(type: "IndigoKeyboardButtonEvent", payload: payload)
  }

  func button(state: UInt64) {
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(payload, "usagePage", 0x0C)
    xpc_dictionary_set_uint64(payload, "usageCode", 0x40)
    xpc_dictionary_set_uint64(payload, "state", state)
    send(type: "IndigoButtonEvent", payload: payload)
  }

  func drain() {
    let done = DispatchSemaphore(value: 0)
    xpc_connection_send_barrier(connection) { done.signal() }
    _ = done.wait(timeout: .now() + 1)
    // XPC's send barrier precedes guest consumption; let the final touch-up arrive before cancellation.
    Thread.sleep(forTimeInterval: 0.08)
  }

  private func send(type: String, payload: xpc_object_t) {
    let message = envelope(type: type, barrier: false)
    xpc_dictionary_set_value(message, "payload", payload)
    xpc_connection_send_message(connection, message)
  }

  private func envelope(type: String, barrier: Bool) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(message, "messageType", type)
    xpc_dictionary_set_string(message, "featureIdentifier", Self.service)
    xpc_dictionary_set_bool(message, "isBarrier", barrier)
    return message
  }
}

// The reply writes before signaling; the waiting thread reads only after a successful wait.
private final class HIDProbeResult: @unchecked Sendable {
  var ok = false
}
