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
@preconcurrency import CoreSimulator
import SimulatorApp

enum HIDError: LocalizedError {
  case simulatorKitUnavailable(String)
  case symbolUnavailable(String)
  case clientClassUnavailable
  case clientCreationFailed(String)
  case disconnected
  case invalidCoordinate
  case shakeFailed(Int32)

  var errorDescription: String? {
    switch self {
    case let .simulatorKitUnavailable(reason): return "SimulatorKit is unavailable: \(reason)"
    case let .symbolUnavailable(symbol): return "SimulatorKit does not export \(symbol)"
    case .clientClassUnavailable: return "SimulatorKit.SimDeviceLegacyHIDClient is unavailable"
    case let .clientCreationFailed(reason): return "could not create the simulator HID client: \(reason)"
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

  init(
    device: SimDevice,
    udid: UUID,
    displayInfo: SimulatorDisplayInfo,
    developerDirectory: String
  ) throws {
    let simulatorKitPath = developerDirectory + "/Library/PrivateFrameworks/SimulatorKit.framework"
    guard let bundle = Bundle(path: simulatorKitPath) else {
      throw HIDError.simulatorKitUnavailable("not found at \(simulatorKitPath)")
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
  }

  func disconnect() {
    queue.sync { client = nil }
  }

  func tap(x: Double, y: Double) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try validate(x: x, y: y)
        perform([
          ScheduledTouch(delay: 0, data: touchData(direction: .down, x: x, y: y)),
          ScheduledTouch(delay: 0.01, data: touchData(direction: .up, x: x, y: y)),
        ])
      } catch {
        Log.message("tap failed: \(error.localizedDescription)")
      }
    }
  }

  func swipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMilliseconds: Int) {
    queue.async { [weak self] in
      guard let self else { return }
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
            data: touchData(direction: .down, x: x, y: y)))
        }
        events.append(ScheduledTouch(
          delay: stepDelay,
          data: touchData(direction: .down, x: x2, y: y2)))
        events.append(ScheduledTouch(
          delay: 0,
          data: touchData(direction: .up, x: x2, y: y2)))
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
        ScheduledTouch(delay: 0, data: buttonData(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeDown), keyCode: 0)),
        ScheduledTouch(delay: 0.01, data: buttonData(
          source: UInt32(ButtonEventSourceHomeButton),
          target: UInt32(ButtonEventTargetHardware),
          direction: UInt32(ButtonEventTypeUp), keyCode: 0)),
      ])
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
        events.append(ScheduledTouch(delay: 0, data: keyData(usage: shiftUsage, direction: UInt32(ButtonEventTypeDown))))
      }
      events.append(ScheduledTouch(delay: 0, data: keyData(usage: usage, direction: UInt32(ButtonEventTypeDown))))
      events.append(ScheduledTouch(delay: 0.01, data: keyData(usage: usage, direction: UInt32(ButtonEventTypeUp))))
      if shift {
        events.append(ScheduledTouch(delay: 0, data: keyData(usage: shiftUsage, direction: UInt32(ButtonEventTypeUp))))
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

  private func touchData(direction: TouchDirection, x: Double, y: Double) -> Data {
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

  // keyData builds a keyboard Indigo message (source/target fixed to the keyboard
  // service); usage is a USB HID usage code.
  private func keyData(usage: UInt32, direction: UInt32) -> Data {
    buttonData(
      source: UInt32(ButtonEventSourceKeyboard),
      target: UInt32(ButtonEventTargetKeyboard),
      direction: direction, keyCode: usage)
  }

  // buttonData hand-builds a single-payload Indigo button/keyboard message. The
  // mach header stays zeroed — SimDeviceLegacyHIDClient fills it on send (the
  // touch path relies on the same). Layout matches FBSimulatorIndigoHID's
  // buttonMessage: eventType byte = IndigoEventTypeButton, payload.eventKind = 2,
  // innerSize = one payload.
  private func buttonData(source: UInt32, target: UInt32, direction: UInt32, keyCode: UInt32) -> Data {
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

  // perform delivers a gesture's events in order on `queue`, blocking until each
  // event's HID delivery completes before moving on. Because `queue` is serial,
  // one gesture finishes entirely before the next begins — so rapid taps stay
  // discrete instead of collapsing into a simultaneous multi-finger touch. Must
  // be called on `queue`.
  private func perform(_ events: [ScheduledTouch]) {
    for event in events {
      if event.delay > 0 {
        Thread.sleep(forTimeInterval: event.delay)
      }
      deliver(event.data)
    }
  }

  // deliver sends one Indigo message and waits for the client's completion. The
  // callback lands on completionQueue (not `queue`, which we are blocking), so
  // there is no self-deadlock. The 1s cap keeps a wedged/disconnected client
  // from hanging shutdown (disconnect() takes `queue` via sync).
  private func deliver(_ data: Data) {
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
  let data: Data
}
