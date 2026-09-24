(** Tempo OTLP/HTTP trace backend for obs-eio.

    Converts each closed [Obs_eio] span into an OTLP [ResourceSpans] message
    and exports it to Tempo's OTLP/HTTP trace-ingestion endpoint.

    {b Export is asynchronous (0.2).} Closing a span only encodes and enqueues
    it; a background fiber on the [sw] passed to {!create} exports batches, one
    OTLP request per batch. A slow or unreachable Tempo never blocks the fiber
    that closed the span. The queue is bounded, so on overflow the oldest span
    is dropped and counted ({!dropped}). A failed export loses its batch and is
    reported on stderr (at most once per 10 s); it does not raise from
    [emit_span]. Call {!flush} before a short-lived process exits. [https://]
    URLs are supported via the system CA bundle.

    Wire format: OTLP protobuf-over-HTTP ([Content-Type:
    application/x-protobuf] against [/v1/traces]), not OTLP/gRPC and not
    OTLP/HTTP+JSON. Message construction and encoding reuse the maintained
    [opentelemetry] package's generated protobuf types
    ([Opentelemetry.Proto.Trace_service]) rather than hand-rolling a wire
    encoder — this package supplies only the [Obs_eio.backend] adapter and
    the HTTP transport (via [https-eio]). See the README's
    "OTLP Encoding" section for why protobuf was chosen over the JSON
    fallback, and why the heavier [opentelemetry-client]/
    [opentelemetry-client-cohttp-eio] packages (built around their own
    background batching collector) are not used here — this backend needs
    only the wire-format types; its own small queue is enough.

    [emit_metric] and [declare_metric] are no-ops: Tempo is trace-only.
    Metrics go to [obs-prometheus-eio].

    {[
      let tempo =
        Obs_tempo.create ~sw ~net:env#net ~clock:env#clock
          ~url:"http://localhost:4318" () in
      let ot =
        Obs_eio.create ~service:"payments-worker"
          ~mono_clock:env#mono_clock ~backend:(Obs_tempo.backend tempo) () in
      Obs_eio.with_span ot "payment.process" (fun sp ->
        Obs_eio.log sp Obs_eio.Info ~fields:[("payment_id", "p_123")] "processing")
    ]} *)

type t
(** A running Tempo exporter. Export is asynchronous (0.2): closing a span
    enqueues it, and a background fiber on [sw] exports batches. A slow or
    unreachable Tempo never blocks the fiber that closed the span. The queue is
    bounded, so on overflow the oldest span is dropped and counted ({!dropped}).
    A failed export loses its batch and is reported on stderr (at most once per
    10 s). Call {!flush} before a short-lived process exits. *)

val create
  :  sw:Eio.Switch.t
     (** Owns the background export fiber. *)
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL of Tempo's OTLP/HTTP receiver, e.g.
         ["http://localhost:4318"]. Must be an [http://] or [https://] URL
         with a host. The ingestion path [/v1/traces] is appended
         automatically. *)
  -> ?timeout:float
     (** Request timeout in seconds. Must be positive. Default: [5.0]. *)
  -> ?headers:(string * string) list
     (** Extra HTTP headers, e.g. auth/proxy headers such as
         [X-Scope-OrgID]. *)
  -> ?max_queued:int
     (** Spans held while Tempo is slow or down. Default: [10_000]. *)
  -> ?max_batch:int
     (** Spans per export request. Default: [500]. *)
  -> unit
  -> t

val backend : t -> Obs_eio.backend

val flush : ?timeout:float -> t -> unit
(** Export everything queued and wait for exports in flight, for at most
    [timeout] seconds (default [5.0]) -- a hard bound: an export still running
    at the deadline is abandoned and its spans reported lost. *)

val dropped : t -> int
