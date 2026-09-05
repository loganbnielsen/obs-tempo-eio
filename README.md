# obs-tempo-eio

Tempo OTLP/HTTP trace backend for [`obs-eio`](https://github.com/loganbnielsen/obs-eio).
Converts each closed span into a single-span OTLP `ResourceSpans` message and pushes it
to Tempo's OTLP/HTTP trace-ingestion endpoint (`/v1/traces`) when the span closes.

Extracted for the [Sun](https://github.com/loganbnielsen/sun) platform, following the
same standalone-package pattern as
[`obs-loki-eio`](https://github.com/loganbnielsen/obs-loki-eio) (logs) and
[`obs-prometheus-eio`](https://github.com/loganbnielsen/obs-prometheus-eio) (metrics).
This package is trace-only.

## Build

```bash
eval $(opam env)
# Until obs-eio is in your switch from OPAM, pin the sibling checkout:
# opam pin add obs-eio ../obs-eio -yn
dune build
```

## Test

```bash
# Unit tests (mock server, no infrastructure)
dune runtest

# Also run the live Tempo round-trip test
TEMPO_URL=http://localhost:4318 TEMPO_QUERY_URL=http://localhost:3200 dune test --force
```

## Public API

```ocaml
val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL of Tempo's OTLP/HTTP receiver, e.g. "http://localhost:4318".
         Ingestion path /v1/traces appended automatically. *)
  -> ?timeout:float
     (** Request timeout in seconds. Default: 5.0. *)
  -> ?headers:(string * string) list
     (** Extra HTTP headers, e.g. auth/proxy headers such as X-Scope-OrgID. *)
  -> unit
  -> Obs_eio.backend
```

No `label_names`/stream-label concept here, unlike `obs-loki-eio`: that's a Loki
stream-cardinality concern, and OTLP resource attributes (this package sends every
`context` field as one) carry no equivalent cardinality restriction to guard against.

HTTPS setup is delegated to `https-eio`, which provides the typed setup errors used by
`create`.

## OTLP Encoding

**Protobuf-over-HTTP, not gRPC and not JSON.** Before writing any wire-format code, this
package checked for an existing, maintained OCaml OTLP/protobuf library rather than
hand-rolling one — see the ticket rationale in `obs-tempo-eio`'s originating discussion.
[`opentelemetry`](https://github.com/ocaml-tracing/ocaml-opentelemetry) (the
`ocaml-tracing` org's core package, actively released through 0.91.x) turned out to fit
well: its `opentelemetry.proto` sub-library is generated directly from the upstream
`opentelemetry-proto` `.proto` sources via `ocaml-protoc`/`pbrt`, and exposes the raw
message types and `encode_pb_*`/`decode_pb_*` functions with no dependency on the rest of
the SDK. This package uses exactly that slice:

```ocaml
module Trace         = Opentelemetry.Proto.Trace
module Resource      = Opentelemetry.Proto.Resource
module Common        = Opentelemetry.Proto.Common
module Trace_service = Opentelemetry.Proto.Trace_service
```

to build one `Trace_service.export_trace_service_request` per span, encode it with
`Pbrt.Encoder`, and POST the resulting bytes with `Content-Type: application/x-protobuf`.

**Deliberately not used:** the `opentelemetry-client`/`opentelemetry-client-cohttp-eio`
packages layered on top of `opentelemetry` (even though the latter is, notably, an
Eio-native OTLP collector client). Those packages own a background batching
collector — spans accumulate in a queue and flush on an interval or size threshold — which
conflicts with `Obs_eio.backend`'s contract: `emit_span` is called synchronously, inline,
on the calling fiber, and *this* backend (like `obs-loki-eio`) owns the decision to push
immediately rather than hand off to a second queue. Pulling in a second exporter runtime
to get one HTTP POST per span would add real dependency weight (`tls-eio`,
`mirage-crypto-rng`, `ambient-context-eio`, `cohttp-eio`) for a batching behavior this
package deliberately avoids. Reusing just the wire-format types and doing the HTTP POST
directly through `https-eio` (same as `obs-loki-eio`) gets the reuse benefit without the
architecture mismatch.

**Why protobuf over the JSON fallback:** OTLP/HTTP+JSON is a legitimate simpler fallback
when no protobuf library is available, but here one *is* available for free — the
`opentelemetry.proto` types round-trip through `encode_pb_*`/`decode_pb_*` exactly as
easily as `encode_json_*`/`decode_json_*`, so there is no complexity reason to prefer the
JSON encoding once a maintained protobuf path exists. Protobuf is also the transport
every other OTLP exporter in the ecosystem defaults to, so it is the safer choice for
interop with collectors other than Tempo later.

**Not used:** OTLP/gRPC. No maintained OCaml gRPC + OTLP integration was found that fits
this package's synchronous, per-span, no-collector-runtime shape; OTLP/HTTP is a fully
supported ingestion path for Tempo and is what this package uses.

## Span Mapping

| `Obs_eio.span_event` field | OTLP field |
|---|---|
| `trace_ctx.trace_id` (`int64 * int64`) | `span.trace_id` (16 bytes, big-endian) |
| `trace_ctx.span_id` (`int64`) | `span.span_id` (8 bytes, big-endian) |
| `parent_span_id` (`int64 option`) | `span.parent_span_id` (8 bytes, big-endian) when `Some`; field omitted when `None` (root span) |
| `name` | `span.name` |
| `service` | resource attribute `service.name` |
| `start_ns` / `end_ns` | `span.start_time_unix_nano` / `end_time_unix_nano` (converted to wall-clock — see Timestamps) |
| `status` | `span.status` (`Status_code_ok` / `Status_code_error` with `message`) |
| `log_entries` | `span.events` (one OTLP span event per log call; `message` becomes the event name, `level` and `fields` become event attributes) |
| `context` | resource attributes, one per key/value pair, alongside `service.name` |

`span.kind` is always `Span_kind_internal` — `span_event` carries no information to
distinguish server/client/producer/consumer spans at this layer.

## Parent/Child Span Linking

`Obs_eio.span_event.parent_span_id` is `Some parent.span_id` when the span was opened
with `Obs_eio.with_span ot ?parent`, `None` for a root span. This backend maps it
directly to OTLP's `span.parent_span_id` (omitted, not zero-filled, when `None`), so
spans opened with `?parent` render as a proper parent/child waterfall in Tempo's trace
view instead of unconnected siblings sharing only a trace id.

## Timestamps

OTLP requires wall-clock epoch nanoseconds; `span_event.start_ns`/`end_ns` and
`log_entry.timestamp_ns` are monotonic. Like `obs-loki-eio`, this backend reads the wall
clock once at span-close time and derives every other timestamp by offsetting backward
from the monotonic deltas — there is no wall-clock read per log entry.

## Error Handling

If Tempo is unreachable or returns a non-2xx status, the backend raises an ordinary
backend exception from `emit_span`. Through `Obs_eio.create`, that exception is caught
and sent to the handle's `on_backend_error` hook (stderr by default) — a Tempo outage
does not affect application control flow. Calling the raw backend directly is
intentionally lower level and will see the exception.

## Buffering and Backpressure

None. `emit_span` pushes synchronously — one HTTP POST per span close, bounded by the
configured timeout — and there is no queue or batching, matching `obs-loki-eio`'s
documented 0.1 behavior for the same reason: a switch-owned queue and flush fiber is
real lifecycle complexity, not something to add speculatively.

## Local Development

A local Tempo instance is only needed for the live round-trip test (`TEMPO_URL=...
TEMPO_QUERY_URL=... dune test --force`); unit tests need nothing running. There is no
convenient native Tempo binary for this ecosystem's usual "run it directly on Linux"
pattern (unlike Redpanda) — Tempo ships as a Docker image and that is what
`platform/local/scripts/ensure-tempo.sh` in the `sun` repo uses, mirroring
`ensure-loki.sh`'s Docker-based approach:

```bash
docker run -d --name tempo \
  -p 4318:4318 -p 3200:3200 \
  -v "$(pwd)/tempo.yaml:/etc/tempo.yaml:ro" \
  grafana/tempo:latest -config.file=/etc/tempo.yaml
```

using a minimal single-binary config:

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 0.0.0.0:4318  # Tempo's default binds the OTLP HTTP
                                  # receiver to 127.0.0.1 only, which a
                                  # Docker port mapping can't reach.

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
```

Query a trace back once a service is pushing spans through this backend:

```bash
curl -H 'Accept: application/json' http://localhost:3200/api/traces/<trace_id_hex>
```

## Out of Scope (v1)

- Batching / async push — `emit_span` is synchronous; each span close does one HTTP POST
- `emit_metric` / `declare_metric` — metrics go to `obs-prometheus-eio`, not Tempo; both
  are no-ops here
- OTLP/gRPC transport — HTTP only
- Span sampling policy — every `with_span` call is exported; sampling is a
  consumer-side concern, not this package's
- A collector in front of Tempo (e.g. an OTel Collector or Grafana Alloy) — this package
  pushes directly to Tempo's OTLP/HTTP receiver
