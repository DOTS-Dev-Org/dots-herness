# Native provider contract

Windows and Linux use the same `shared/NativeProviderRouter.cs` implementation.
The chat loop runs in-process and does not require a separate web host.

Provider state is metadata plus credential references. Windows credentials are
protected before being written to the provider credential directory; the JSON
state file contains no API secret. Routes are ordered by priority and only
active accounts with credentials participate in fallback.

Supported request forms are OpenAI-compatible Chat Completions and
Anthropic Messages. The normalized response retains assistant text, tool-call
metadata, and usage. Retryable network/429/5xx failures can move to the next
route; permanent 4xx failures are returned immediately.

The optional gateway listens only on loopback, requires its bearer share key,
and provides non-streaming model-list and chat-completion endpoints. It is
created only when the user enables sharing.
