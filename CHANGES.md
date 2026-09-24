# Changes

## 0.2.0

- **Asynchronous export (breaking).** `create` takes `~sw` and returns a `t`;
  `backend t` is the `Obs_eio` backend. Closing a span only enqueues it, and a
  background fiber exports batches (`?max_batch`, default 500) in one OTLP request
  each. A slow or unreachable Tempo no longer blocks the fiber that closed the span
  (Sol OBS-048).
- The queue is bounded (`?max_queued`, default 10 000). On overflow the oldest span
  is dropped and counted (`dropped t`).
- A failed export loses its batch and is reported on stderr (at most once per 10 s),
  instead of raising from `emit_span`.
- `flush ?timeout t` exports everything queued and waits for in-flight requests.

## 0.1.0

- Initial standalone OPAM package: `obs-eio` Tempo backend exporting spans over
  OTLP/HTTP (protobuf), reusing the `opentelemetry` package's generated wire
  types instead of hand-rolling protobuf encoding.
