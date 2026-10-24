# Dots Harness for macOS

The macOS app is a native SwiftUI application. Provider accounts, direct
requests, fallback routing, conversation storage, and the optional loopback
gateway are implemented in `DotsHarnessCore`.

## Provider connections

Built-in providers display canonical names only. `GPT` uses the official
browser sign-in flow; `OpenAI` is a separate API-key connection. Credentials
are stored in Keychain and never written to `provider-state.json`.

`Custom API` accepts an HTTP/HTTPS base URL, optional API key, model prefix,
and OpenAI-compatible or Anthropic-compatible protocol. No endpoint is probed
until the user presses Test or sends a request.

## Local models and sharing

Model downloads are explicit. Start does not download missing files. The
Turkish speech runtime (about 55 MB) is the one automatic download: it starts
in the background the first time Turkish speech is requested after the speech
model is installed, and the system voice is used until it arrives. Sharing
starts a loopback-only gateway only after the user enables it;
requests require the generated share key and are non-streaming in this first
version.

## Turkish speech runtime and signing

The app does not bundle sherpa-onnx or onnxruntime. The runtime downloads both
upstream xcframework zips from GitHub. Each archive is checked against the
SHA-256 pinned in `LocalSpeechRuntime`
(`Sources/DotsHarnessCore/LocalPiperSpeechSynthesizer.swift`), unpacked with
`ditto` into Application Support, and its two binaries are hashed against their
own pins before every `dlopen` through `Sources/PiperRuntimeC`. A mismatch
deletes the runtime so it is fetched again. The archive pins are the SwiftPM
checksums of sherpa-onnx v1.13.6 and onnxruntime-libs v1.27.1; update all pins
together.

`scripts/package-dmg.sh` signs with `CODE_SIGN_IDENTITY`, or the first
`Apple Development` or `Developer ID Application` identity in the login
keychain. Nested frameworks are signed before the app bundle. The app is not
built with the hardened runtime, so the dlopen'd libraries load without library
validation. Private keys and certificate exports never go into the repository.

Build and test:

```sh
swift test
```
