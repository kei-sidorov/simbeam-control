import Darwin
import Foundation
import IOSurface

signal(SIGPIPE, SIG_IGN)

let options: CLIOptions
do {
  options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch CLIError.help {
  print(CLIOptions.usage)
  exit(0)
} catch CLIError.protocolQuery {
  print(ControlProtocol.version)
  exit(0)
} catch {
  StartupFailure.invalidArguments.report(error)
  Log.message(CLIOptions.usage)
  exit(2)
}

let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
  ?? "/Applications/Xcode.app/Contents/Developer"

let connection: SimulatorConnection
do {
  connection = try SimulatorConnection(
    udid: options.udid,
    developerDirectory: developerDirectory)
} catch {
  ((error as? SimulatorConnectionError)?.startupFailure ?? .coreSimulatorUnavailable).report(error)
  exit(1)
}

let displayInfo = connection.displayInfo
let encoder = VideoEncoder(
  fps: options.fps,
  keyframeIntervalMilliseconds: options.keyframeIntervalMilliseconds,
  bitrate: options.bitrate,
  scale: options.scale,
  udid: options.udid
) { sourceWidth, sourceHeight, width, height in
  Log.json([
    "ready": true,
    "protocol": ControlProtocol.version,
    "width": Int((Double(sourceWidth) / displayInfo.nativeScale).rounded()),
    "height": Int((Double(sourceHeight) / displayInfo.nativeScale).rounded()),
    "scale": displayInfo.nativeScale,
    "encoded_width": width,
    "encoded_height": height,
  ])
}

let lifecycleQueue = DispatchQueue(label: "com.simbeam.control.lifecycle")
var hid: HIDController?
var running = false
var shuttingDown = false

func shutdown(_ status: Int32) {
  lifecycleQueue.async {
    guard !shuttingDown else { return }
    shuttingDown = true
    FileHandle.standardInput.readabilityHandler = nil
    hid?.disconnect()
    connection.detach()
    encoder.stop()
    exit(status)
  }
}

// Signals are handled from the moment the device resolves, so a cold-boot
// framebuffer wait can be interrupted instead of leaving the parent to kill the
// helper. Before the stream is up, cancelling unblocks the wait; the startup
// path then detaches and exits.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
func terminate() {
  lifecycleQueue.async {
    if running {
      shutdown(0)
    } else {
      connection.cancel()
    }
  }
}
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: lifecycleQueue)
interruptSource.setEventHandler { terminate() }
interruptSource.resume()
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: lifecycleQueue)
terminateSource.setEventHandler { terminate() }
terminateSource.resume()

let initialSurface: IOSurface
do {
  initialSurface = try connection.attach(
    callbackQueue: encoder.queue,
    startupTimeout: options.startupTimeout,
    surfaceHandler: encoder.accept(surface:))
} catch SimulatorConnectionError.cancelled {
  Log.message("startup cancelled before the simulator framebuffer was available")
  encoder.stop()
  exit(0)
} catch {
  ((error as? SimulatorConnectionError)?.startupFailure ?? .displayNotReady).report(error)
  encoder.stop()
  exit(1)
}

// The connection is attached, so `shutdown` can tear everything down from here:
// arm it before the remaining setup, which talks to the simulator and can take
// a while. A signal in this window must stop the process, not be swallowed.
lifecycleQueue.sync { running = true }
if connection.isCancelled {
  // A signal delivered during the startup wait only cancelled the wait.
  shutdown(0)
  dispatchMain()
}

// HID comes up before the encoder so that every typed startup failure still
// precedes the ready handshake.
let hidController: HIDController
do {
  hidController = try HIDController(
    device: connection.device,
    udid: options.udid,
    displayInfo: connection.displayInfo,
    developerDirectory: developerDirectory)
} catch {
  StartupFailure.hidUnavailable.report(error)
  connection.detach()
  encoder.stop()
  exit(1)
}
lifecycleQueue.sync { hid = hidController }

do {
  try encoder.start(surface: initialSurface)
} catch {
  StartupFailure.encoderFailed.report(error)
  hidController.disconnect()
  connection.detach()
  encoder.stop()
  exit(1)
}

let input = ControlInput(encoder: encoder, hid: hidController) { shutdown(0) }
input.start()

dispatchMain()
