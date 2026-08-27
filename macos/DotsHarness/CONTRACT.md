# Native provider contract

The application owns the provider control plane. It does not require a helper
process, a machine identity file, a private header, or a fixed external port.

Provider state contains account metadata and credential references only:

- account ID, canonical provider ID, account name/email, model, protocol,
  priority, active state;
- custom endpoint name, URL, model prefix, protocol, and secret reference;
- secrets in the platform credential store.

The native agent normalizes messages, tool calls, responses, and usage. Active
routes are attempted by priority. Network failures, rate limits, and server
errors can move to the next active route; invalid requests and authorization
errors remain visible. An expired browser session gets one refresh attempt.

The optional local gateway exposes `GET /v1/models` and non-streaming
`POST /v1/chat/completions` on loopback. It requires a bearer share key and
stops when sharing is disabled.
