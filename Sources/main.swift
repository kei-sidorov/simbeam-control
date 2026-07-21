import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let options: CLIOptions
do {
  options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch CLIError.help {
  print(CLIOptions.usage)
  exit(0)
} catch {
  Log.message("error: \(error.localizedDescription)")
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
  Log.message("error: \(error.localizedDescription)")
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
    "width": Int((Double(sourceWidth) / displayInfo.nativeScale).rounded()),
    "height": Int((Double(sourceHeight) / displayInfo.nativeScale).rounded()),
    "scale": displayInfo.nativeScale,
    "encoded_width": width,
    "encoded_height": height,
  ])
}

do {
  let initialSurface = try connection.attach(
    callbackQueue: encoder.queue,
    surfaceHandler: encoder.accept(surface:))
  try encoder.start(surface: initialSurface)
} catch {
  Log.message("error: \(error.localizedDescription)")
  exit(1)
}

let hid: HIDController
do {
  hid = try HIDController(
    device: connection.device,
    udid: options.udid,
    displayInfo: connection.displayInfo,
    developerDirectory: developerDirectory)
} catch {
  Log.message("error: \(error.localizedDescription)")
  connection.detach()
  encoder.stop()
  exit(1)
}

let lifecycleQueue = DispatchQueue(label: "com.simbeam.control.lifecycle")
var shuttingDown = false
func shutdown(_ status: Int32) {
  lifecycleQueue.async {
    guard !shuttingDown else { return }
    shuttingDown = true
    FileHandle.standardInput.readabilityHandler = nil
    hid.disconnect()
    connection.detach()
    encoder.stop()
    exit(status)
  }
}

let input = ControlInput(encoder: encoder, hid: hid) { shutdown(0) }
input.start()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: lifecycleQueue)
interruptSource.setEventHandler { shutdown(0) }
interruptSource.resume()
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: lifecycleQueue)
terminateSource.setEventHandler { shutdown(0) }
terminateSource.resume()

dispatchMain()
