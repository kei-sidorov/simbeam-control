# simbeam-control repository guide

## Mission

`simbeam-control` is a small macOS helper for one booted iOS Simulator. It exposes only:

1. A low-latency constant-frame-rate H.264 screen stream.
2. Tap.
3. Swipe.
4. Shake.

It is consumed by the simbeam Go daemon. Keep this helper narrow. Do not add gRPC, protobuf,
device management, app lifecycle commands, XCTest, logging, accessibility, real-device support,
or video recording.

The Go daemon has intentionally not been adapted yet. Change it only when explicitly requested.

## Supported environment

- Development and runtime validation: macOS 26.5, Xcode 26.4.1.
- Deployment target: macOS 13.0.
- Product: unsigned universal executable (`arm64` and `x86_64`).
- iOS Simulator only; a full Xcode installation and completed first-launch setup are required.
- Xcode 27 resize mode is architecturally anticipated but has not received its compatibility pass.

## Process contract

Invocation:

```sh
simbeam-control --udid <UDID> [--fps 30] [--keyframe-interval-ms 2000] \
  [--bitrate 4000000] [--scale 1.0]
```

stdout is binary-only. Each record is:

```text
[4-byte big-endian payload length]
[1-byte flags; bit 0 means IDR]
[8-byte big-endian monotonic PTS in microseconds]
[H.264 Annex-B access unit]
```

Every IDR contains in-band SPS and PPS. PTS is the measured monotonic submission time, not a
synthetic frame counter.

stderr carries the startup handshake and logs. The first line after successful attachment is JSON:

```json
{"ready":true,"width":402,"height":874,"scale":3,"encoded_width":300,"encoded_height":654}
```

Rotation or a genuine framebuffer resize emits another handshake, forces an IDR, and updates SPS
and PPS. The parent must treat the new handshake as a decoder-geometry change.

stdin accepts newline-delimited JSON:

```json
{"type":"tap","x":195.0,"y":422.0}
{"type":"swipe","x1":195,"y1":600,"x2":195,"y2":200,"duration_ms":250}
{"type":"shake"}
{"type":"keyframe"}
{"type":"quality","bitrate":2500000,"fps":24}
```

The process stops cleanly on stdin EOF, SIGINT, or SIGTERM.

## Architecture

- `SimulatorConnection.swift`: resolves the requested booted `SimDevice`, locates the main
  IOSurface-renderable display port, attaches callbacks, and detaches cleanly.
- `VideoEncoder.swift`: wraps the IOSurface, performs optional Core Image rotation/scaling,
  converts BGRA to NV12, and feeds the hardware VideoToolbox H.264 encoder.
- `SimulatorOrientation.swift`: reads the per-UDID Simulator window orientation from
  `com.apple.iphonesimulator` preferences. Polling runs on a utility queue, never the video queue.
- `AnnexB.swift` and `FramedOutput.swift`: add SPS/PPS to IDRs and write the binary framing.
- `HIDController.swift`: sends SimulatorKit Indigo single-touch messages for tap/swipe and uses
  `simctl` for shake.
- `ObjCExceptionBridge.*`: this project's small, independently written `@try/@catch` boundary.
  Swift cannot catch Objective-C exceptions thrown by private proxy selectors.
- `ControlInput.swift`: parses the intentionally tiny JSON command surface.

Video cadence is timer-driven and continues on static screens. Important VideoToolbox properties:
real-time mode, no frame reordering, max frame delay zero, Baseline H.264, CAVLC, hardware encoder,
configurable average bitrate, configurable keyframe interval, and forced IDR on request.

## Rotation and resize

Xcode 26 keeps the IOSurface in native portrait geometry while Simulator.app rotates its window.
The orientation therefore cannot be inferred from IOSurface dimensions. Read
`SimulatorWindowOrientation` / `SimulatorWindowRotationAngle`, rotate the fixed canvas, swap point
and encoded dimensions, force an IDR, and emit a new handshake.

Actual IOSurface replacement and dimensions are a separate, authoritative signal. A new surface
rebuilds the conversion pools and encoder when geometry changes. This split is intentional for
Xcode 27's resizable Device Hub, but Xcode 27 private APIs and live resize behavior must be tested
before claiming support.

Manual rotation validation on Xcode 26.4.1 established:

- `LandscapeLeft` is stored as `90` degrees.
- Landscape handshake: 874 x 402 points; test encode: 654 x 300 at scale 0.25.
- Portrait handshake: 402 x 874 points; test encode: 300 x 654 at scale 0.25.
- The transition produces an immediate IDR and remains continuous.

## Private APIs and third-party material

The executable uses the CoreSimulator and SimulatorKit installations supplied by Xcode. It does
not bundle private frameworks.

The minimal private headers and `CoreSimulator.tbd` under `PrivateHeaders/` are vendored from
facebook/idb commit `8509ca666b5983171a73338114b7d0325ae15bf1` under the MIT License. Preserve:

- Copyright/license headers in vendored files.
- `PrivateHeaders/LICENSE.facebook-idb`.
- The top-level `NOTICE` attribution and pinned commit SHA.

The `.tbd` is only a text linker stub describing CoreSimulator exports. At runtime the actual
CoreSimulator framework is loaded from the Xcode/CoreSimulator installation. Never bundle idb or
CoreSimulator framework binaries.

idb is prior art for the IOSurface attachment, VideoToolbox configuration, and Indigo HID path.
Project-owned code should remain independently named and narrowly implemented. Do not copy more
idb code when a small local implementation is straightforward.

## Build and verification

GitHub Actions uses the official `macos-26` runner and explicitly selects Xcode 26.4.1. Pushes and
pull requests run static analysis plus a universal build. Tags matching `v*` create a GitHub
Release containing `simbeam-control_<version>_darwin_universal.tar.gz` with the executable under
`bin/`; the `kei-sidorov/homebrew-simbeam` tap publishes it as
`kei-sidorov/simbeam/simbeam-control`. The formula has been validated with strict online audit,
installation, `brew test`, and universal-architecture inspection.

Universal release build:

```sh
./Scripts/build-universal.sh
```

Output:

```text
.build/release/simbeam-control
```

Fast native debug build:

```sh
xcodebuild -project simbeam-control.xcodeproj \
  -scheme simbeam-control \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Static analysis:

```sh
xcodebuild -project simbeam-control.xcodeproj \
  -scheme simbeam-control \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO analyze
```

Before handing off changes, verify as appropriate:

- `git diff --check`.
- Debug build and static analysis.
- Universal binary contains `x86_64 arm64` (`lipo -archs`).
- `otool -L` shows system frameworks and weak-linked CoreSimulator, with no bundled framework.
- Framed output parses completely; PTS is monotonic and close to the selected CFR cadence.
- ffprobe reports H.264 Baseline and `yuv420p`.
- IDRs contain SPS/PPS and appear periodically and on demand.
- Static screens continue producing frames.
- Rotation produces a new handshake, SPS/PPS, and immediate IDR.
- Tap, swipe, and shake visibly actuate the selected Simulator.

Previously validated on the active iPhone 17 Pro / iOS 26.1 Simulator: 30 fps CFR, live fps and
bitrate changes, periodic and forced IDR, tap, smooth swipe, shake, portrait/landscape rotation,
clean shutdown, invalid-UDID failure, and universal Release output.

## Working conventions

- Preserve unrelated user changes and untracked files.
- Do not stage, commit, branch, push, or modify the Go daemon unless explicitly requested.
- Prefer manual Simulator GUI actions when they are safer or clearer; tell the user exactly what
  to do and why.
- Keep stdout pure binary video. Diagnostics and handshakes belong on stderr.
- Keep the helper small and fail fast when the target is missing, not booted, or lacks a display.
- Treat private API compatibility as version-specific. Never claim a new Xcode version works
  without a real build and Simulator test.
