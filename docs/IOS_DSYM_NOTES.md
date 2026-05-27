# iOS dSYM symbolication notes

## TL;DR

After a TestFlight upload App Store Connect may report:

> Upload Symbols Failed
> The archive did not include a dSYM for AgoraRtcKit.framework
> The archive did not include a dSYM for AgoraRtmKit.framework
> The archive did not include a dSYM for <AgoraAudio…Extension>.framework
> The archive did not include a dSYM for AgoraIrisRTC.framework

These are **non-blocking** — the build is accepted and works on
TestFlight. They only mean that if a crash happens inside an Agora
framework, the stack trace surfaced in Xcode Organizer / Crashlytics
won't be human-readable for those frames.

## Why

Agora distributes their iOS SDK as `.xcframework` packages of
already-compiled binaries (`AgoraRtcKit.xcframework`,
`AgoraRtmKit.xcframework`, `AgoraIrisRTC_iOS.xcframework`, plus a few
audio/video extension dylibs under `AgoraRtcEngine_iOS/`). **None of
these xcframeworks ship with their `.dSYM` bundles** in the
CocoaPods feed.

When Xcode archives the app, it can only generate dSYMs for code
**it compiles itself** (Runner + Flutter framework + pods we
compile from source like `permission_handler_apple`). For
precompiled binaries that arrived as `.xcframework`, Xcode just
embeds the binary; there's no source / IR to generate a dSYM from.

The Podfile already configures `DEBUG_INFORMATION_FORMAT =
dwarf-with-dsym` + `GCC_GENERATE_DEBUGGING_SYMBOLS = YES` for
Release and Profile builds across every pod target, so the dSYMs
we *can* produce are produced.

## What we get vs what we miss

| Code | dSYM generated? |
|---|---|
| `Runner.app` (our Swift + Obj-C) | ✓ |
| Flutter framework | ✓ (bundled by Flutter) |
| Source-compiled pods (e.g. permission_handler_apple) | ✓ |
| Agora xcframeworks (Rtc, Rtm, Iris, extensions) | ✗ (Agora doesn't ship them) |
| Firebase pods | ✓ (Firebase ships dSYMs) |

## Fixes

Only Agora can ship the missing dSYMs. Options:

1. **Accept the warnings** — recommended for now. Crashes inside our
   own code are still symbolicated. Crashes inside Agora are rare and
   their stack trace at least reaches the call site in our code.
2. **Download dSYMs from Agora dev portal** — Agora occasionally
   publishes per-version dSYMs at
   <https://docs.agora.io/en/all-products/downloads>. They'd need to
   be uploaded manually to App Store Connect per archive.
3. **Switch SDK** — if Agora ever moves to publishing dSYMs in the
   pod feed, the warnings vanish automatically (no app-side change).

## Verification after a build

```
flutter build ios --release --no-codesign
find build/ios -name '*.dSYM' -type d
```

Expected: `Runner.app.dSYM` (+ a handful for the source-compiled
pods). Missing: anything starting with `Agora…`.
