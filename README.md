# simbeam-control

`simbeam-control` is a small macOS command-line tool for one booted iOS Simulator. It streams the
display as framed H.264 and accepts tap, swipe, shake, keyframe, and quality commands on stdin.
It has no gRPC, protobuf, device-management, or real-device support.

The current implementation is verified with Xcode 26.4.1 on macOS 26.5 and has a macOS 13.0
deployment target. It dynamically uses the CoreSimulator installation already present on a Mac
that has completed Xcode first-launch setup; no private framework is bundled with the executable.

## Install with Homebrew

The universal release is available from the simbeam tap:

```sh
brew install kei-sidorov/simbeam/simbeam-control
```

The formula requires a full Xcode 26.4.1 or newer installation because the executable uses the
CoreSimulator and SimulatorKit frameworks supplied by Xcode.

## Build

Full Xcode is required and should be selected with `xcode-select`.

```sh
./Scripts/build-universal.sh
```

The unsigned universal executable is written to `.build/release/simbeam-control`. The script builds
both `arm64` and `x86_64`; no Xcode GUI setup or signing identity is required.

GitHub Actions runs the same universal build and static analysis on the official `macos-26` runner
with Xcode 26.4.1. Version tags (`v*`) publish a tarball containing `bin/simbeam-control` for use by
the Homebrew tap.

For a fast native-architecture debug build:

```sh
xcodebuild -project simbeam-control.xcodeproj \
  -scheme simbeam-control \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## Run

The parent process supplies a booted Simulator UDID. `simbeam-control` does not list, boot, or
otherwise manage devices.

```sh
.build/release/simbeam-control \
  --udid 23C94B4C-3DF8-4551-8672-055F9187EABB \
  --fps 30 \
  --keyframe-interval-ms 2000 \
  --bitrate 4000000 \
  --scale 1.0
```

The process exits when stdin closes or it receives SIGINT/SIGTERM. Stdout is always binary video;
logs and the startup handshake are written to stderr.

## stderr handshake

The first stderr line after successful attachment is JSON:

```json
{"ready":true,"width":402,"height":874,"scale":3,"encoded_width":1206,"encoded_height":2622}
```

`width` and `height` are Simulator points, while `scale` is the native display scale.
`encoded_width` and `encoded_height` are the actual even-sized video dimensions after `--scale`.
A framebuffer surface-size or Simulator orientation change rebuilds the encoder when needed,
forces an IDR, and emits an updated line before video continues at the new geometry.

## stdout video framing

Each H.264 access unit is one record:

```text
[4-byte big-endian N][1-byte flags][8-byte big-endian pts_micros][N bytes Annex-B H.264]
```

- `flags & 1` marks an IDR/keyframe.
- Every IDR includes SPS and PPS before its slice NAL units.
- `pts_micros` is the measured monotonic frame-submission time, not a synthetic frame counter.
- The encoder emits at constant cadence even when the Simulator screen is static.
- H.264 uses Baseline profile, `yuv420p`, no B-frame reordering, and VideoToolbox real-time mode.

## stdin control

stdin is newline-delimited JSON, one object per line. Coordinates are in Simulator points.

```json
{"type":"tap","x":195.0,"y":422.0}
{"type":"swipe","x1":195,"y1":600,"x2":195,"y2":200,"duration_ms":250}
{"type":"shake"}
{"type":"keyframe"}
{"type":"quality","bitrate":2500000,"fps":24}
```

`keyframe` is coalesced if several requests arrive before the next cadence tick. `quality` updates
the VideoToolbox bitrate and/or the CFR timer without restarting the process. `shake` posts
`com.apple.UIKit.SimulatorShake` through `simctl`; touch events use SimulatorKit's Indigo HID path.

## idb attribution

Private declarations and the small exception/HID glue are adapted from
[`facebook/idb@8509ca666b5983171a73338114b7d0325ae15bf1`](https://github.com/facebook/idb/tree/8509ca666b5983171a73338114b7d0325ae15bf1),
including the framebuffer pattern from
[`FBFramebuffer.swift`](https://github.com/facebook/idb/blob/8509ca666b5983171a73338114b7d0325ae15bf1/FBSimulatorControl/Framebuffer/FBFramebuffer.swift),
the VideoToolbox configuration from
[`FBSimulatorVideoStream.swift`](https://github.com/facebook/idb/blob/8509ca666b5983171a73338114b7d0325ae15bf1/FBSimulatorControl/Framebuffer/FBSimulatorVideoStream.swift),
and touch message construction from
[`FBSimulatorIndigoHID.swift`](https://github.com/facebook/idb/blob/8509ca666b5983171a73338114b7d0325ae15bf1/FBSimulatorControl/HID/FBSimulatorIndigoHID.swift).

See [NOTICE](NOTICE) and `PrivateHeaders/LICENSE.facebook-idb`.

## Rotation and resize

Xcode 26 keeps an iPhone IOSurface in its native portrait dimensions when Simulator.app rotates the
device. `simbeam-control` reads the per-device Simulator window orientation, rotates that fixed
canvas before encoding, swaps the point/video dimensions in the handshake, and forces an IDR.
Orientation preferences are polled off the video queue so they cannot block CFR frame submission.

Actual IOSurface replacement and size changes are handled independently and remain authoritative
for framebuffer geometry. This separation also matches Xcode 27's resizable Simulator/Device Hub
model: a changed surface size is consumed directly, while orientation remains metadata. Xcode 27
should receive a dedicated compatibility pass before production use because its private framework
surface and resize behavior may change between releases.
