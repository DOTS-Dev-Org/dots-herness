# HerNess Chrome Extension backend

This MV3 extension is the explicit `Extension` backend. It owns only tabs
recorded in `chrome.storage.local` with a lease, run ID, scope, tab ID, window
ID, and expiration time.

The service worker performs cleanup on normal `cleanup` messages, Native
Messaging disconnect, `tabs.onRemoved`, Chrome startup, and a 30-second-or-
later alarm sweep. Alarm cleanup is eventual recovery, not a real-time
guarantee. A closed Chrome process is reported by the host as
`PendingRecovery` until Chrome starts again.

Load this directory as an unpacked extension during development. The Native
Messaging manifest must be installed per-user with the real extension ID and
an absolute executable path; use the template only as an input to the host
installer. The native host must validate the request scope and must never
accept a backend argument from the model.

The host protocol is framed by Chrome Native Messaging. Messages use these
request types:

- `ping`
- `open` with `scope` and `url`
- `navigate` with `scope`, `leaseID`, and `url`
- `close` with `scope` and `leaseID`
- `cleanup` with `scope`

Every response includes the request ID and either `{ "ok": true, "result":
... }` or `{ "ok": false, "error": "..." }`.
