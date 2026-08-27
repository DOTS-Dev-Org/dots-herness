# Native provider contract

The Avalonia application owns provider state, authentication adapters, direct
request transports, fallback, and the optional local gateway. It has no
dependency on a separate router process, machine identity file, private CLI
header, or fixed control-plane port.

The shared .NET 8 core normalizes OpenAI-compatible Chat Completions and
Anthropic Messages. Active routes are ordered by priority. Network timeouts,
connection failures, rate limits, and 5xx responses are retryable; malformed
requests and authorization failures are not hidden by fallback.

The loopback gateway exposes only model discovery and non-streaming chat
completion. A secure share key is required and the listener closes when
sharing stops.
