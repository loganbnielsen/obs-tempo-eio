(** Tempo OTLP/HTTP trace backend for obs-eio.

    Converts each closed [Obs_eio] span into a single-span OTLP
    [ResourceSpans] message and pushes it to Tempo's OTLP/HTTP
    trace-ingestion endpoint synchronously when the span closes — one HTTP
    POST per span, which can block the closing fiber up to the configured
    request timeout. There is no buffering, batching, or backpressure; this
    is the 0.1 behavior, not a temporary gap, matching [obs-loki-eio]'s
    equivalent choice for its push to Loki. If Tempo is unreachable or
    returns a non-2xx response, the backend raises an ordinary exception
    from [emit_span]; [Obs_eio] catches backend exceptions and routes them
    to the handle's [on_backend_error] hook, so application code never sees
    the failure unless it calls the raw backend directly. [https://] URLs
    are supported via the system CA bundle; TLS-setup failures follow the
    same backend-error path.

    Wire format: OTLP protobuf-over-HTTP ([Content-Type:
    application/x-protobuf] against [/v1/traces]), not OTLP/gRPC and not
    OTLP/HTTP+JSON. Message construction and encoding reuse the maintained
    [opentelemetry] package's generated protobuf types
    ([Opentelemetry.Proto.Trace_service]) rather than hand-rolling a wire
    encoder — this package supplies only the [Obs_eio.backend] adapter and
    the synchronous HTTP transport (via [https-eio]). See the README's
    "OTLP Encoding" section for why protobuf was chosen over the JSON
    fallback, and why the heavier [opentelemetry-client]/
    [opentelemetry-client-cohttp-eio] packages (built around their own
    background batching collector) are not used here — this backend needs
    only the wire-format types, not a second exporter runtime competing
    with [Obs_eio]'s own synchronous delivery contract.

    [emit_metric] and [declare_metric] are no-ops: Tempo is trace-only.
    Metrics go to [obs-prometheus-eio].

    {[
      let tempo =
        Obs_tempo.create ~net:env#net ~clock:env#clock
          ~url:"http://localhost:4318" () in
      let ot =
        Obs_eio.create ~service:"payments-worker"
          ~mono_clock:env#mono_clock ~backend:tempo () in
      Obs_eio.with_span ot "payment.process" (fun sp ->
        Obs_eio.log sp Obs_eio.Info ~fields:[("payment_id", "p_123")] "processing")
    ]} *)

val create
  :  net:_ Eio.Net.t
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
  -> unit
  -> Obs_eio.backend
