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

Runtime and model downloads are explicit. Start does not download missing
files. Sharing starts a loopback-only gateway only after the user enables it;
requests require the generated share key and are non-streaming in this first
version.

Build and test:

```sh
swift test
```
