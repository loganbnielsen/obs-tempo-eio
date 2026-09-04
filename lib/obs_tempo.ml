module Trace = Opentelemetry.Proto.Trace
module Resource = Opentelemetry.Proto.Resource
module Common = Opentelemetry.Proto.Common
module Trace_service = Opentelemetry.Proto.Trace_service

(* ------------------------------------------------------------------ *)
(* HTTP client (https-eio)                                             *)
(* ------------------------------------------------------------------ *)

let http_post ~net ~clock ~timeout ~headers ~url ~body =
  let push_url =
    Uri.with_path (Uri.of_string url) "/v1/traces" |> Uri.to_string
  in
  let headers = ("Content-Type", "application/x-protobuf") :: headers in
  match
    Https_eio.request ~net ~clock ~timeout ~meth:`POST ~url:push_url ~headers ~body
      ~max_response_bytes:(64 * 1024) ()
  with
  | Ok (code, _body) when code >= 200 && code < 300 -> Ok ()
  | Ok (code, body) ->
    let truncated = String.sub body 0 (min (String.length body) 512) in
    let detail = if truncated = "" then "" else ": " ^ String.trim truncated in
    Error (Printf.sprintf "Tempo returned HTTP %d%s" code detail)
  | Error e -> Error ("Tempo push: " ^ Https_eio.request_error_to_string e)

(* ------------------------------------------------------------------ *)
(* obs-eio -> OTLP value/attribute mapping                              *)
(* ------------------------------------------------------------------ *)

let key_value key value =
  Common.make_key_value ~key ~value:(Common.String_value value) ()

let resource_attributes ~service context =
  key_value "service.name" service
  :: List.map (fun (k, v) -> key_value k v) context

let level_string = function
  | Obs_eio.Debug -> "debug"
  | Obs_eio.Info -> "info"
  | Obs_eio.Warn -> "warn"
  | Obs_eio.Error -> "error"

let otlp_status = function
  | `Ok -> Trace.make_status ~code:Trace.Status_code_ok ()
  | `Error message -> Trace.make_status ~code:Trace.Status_code_error ~message ()

(* Tempo/OTLP timestamps are wall-clock epoch nanoseconds; [span_event]'s
   [start_ns]/[end_ns] are monotonic. Derive wall-clock instants the same
   way obs-loki-eio derives per-entry log timestamps: read the wall clock
   once at close time and offset backward by the monotonic delta. *)
let span_event_of_log_entry ~close_wall_ns ~end_ns (entry : Obs_eio.log_entry) =
  let time_unix_nano =
    Int64.sub close_wall_ns (Int64.sub end_ns entry.timestamp_ns)
  in
  let attributes =
    key_value "level" (level_string entry.level)
    :: List.map (fun (k, v) -> key_value k v) entry.fields
  in
  Trace.make_span_event ~time_unix_nano ~name:entry.message ~attributes ()

let trace_id_bytes (hi, lo) =
  let b = Bytes.create 16 in
  Bytes.set_int64_be b 0 hi;
  Bytes.set_int64_be b 8 lo;
  b

let span_id_bytes id =
  let b = Bytes.create 8 in
  Bytes.set_int64_be b 0 id;
  b

let wall_now_ns clock = Int64.of_float (Eio.Time.now clock *. 1e9)

(* ------------------------------------------------------------------ *)
(* Payload construction                                                 *)
(* ------------------------------------------------------------------ *)

(* No [parent_span_id]: [Obs_eio.span_event] carries only this span's own
   [trace_ctx] (trace_id + this span's span_id, per [Obs_eio.with_span]'s
   doc on manual nesting) — there is no field to recover the parent span id
   from. Spans emitted by this backend share a trace_id but are not linked
   into a parent/child waterfall in Tempo's UI unless/until [span_event]
   itself carries a parent span id. *)
let resource_spans_of_span_event (e : Obs_eio.span_event) ~close_wall_ns =
  let start_time_unix_nano =
    Int64.sub close_wall_ns (Int64.sub e.end_ns e.start_ns)
  in
  let span =
    Trace.make_span
      ~trace_id:(trace_id_bytes e.trace_ctx.Obs_trace.trace_id)
      ~span_id:(span_id_bytes e.trace_ctx.Obs_trace.span_id)
      ~name:e.name
      ~kind:Trace.Span_kind_internal
      ~start_time_unix_nano
      ~end_time_unix_nano:close_wall_ns
      ~events:(List.map (span_event_of_log_entry ~close_wall_ns ~end_ns:e.end_ns) e.log_entries)
      ~status:(otlp_status e.status)
      ()
  in
  let resource =
    Resource.make_resource ~attributes:(resource_attributes ~service:e.service e.context) ()
  in
  let scope_spans = Trace.make_scope_spans ~spans:[ span ] () in
  Trace.make_resource_spans ~resource ~scope_spans:[ scope_spans ] ()

let encode_request resource_spans =
  let request = Trace_service.make_export_trace_service_request ~resource_spans:[ resource_spans ] () in
  let encoder = Pbrt.Encoder.create () in
  Trace_service.encode_pb_export_trace_service_request request encoder;
  Pbrt.Encoder.to_string encoder

(* ------------------------------------------------------------------ *)
(* Backend                                                              *)
(* ------------------------------------------------------------------ *)

let validate_url url =
  let uri = Uri.of_string url in
  let scheme = Uri.scheme uri |> Option.map String.lowercase_ascii in
  (match scheme with
   | Some "http" | Some "https" -> ()
   | _ -> invalid_arg "Obs_tempo.create: url must use http:// or https://");
  if Uri.host uri = None then
    invalid_arg "Obs_tempo.create: url must include a host"

let create ~net ~clock ~url ?(timeout = 5.0) ?(headers = []) () : Obs_eio.backend =
  if timeout <= 0. || classify_float timeout = FP_nan then
    invalid_arg "Obs_tempo.create: timeout must be positive";
  validate_url url;
  let emit_span (e : Obs_eio.span_event) =
    let close_wall_ns = wall_now_ns clock in
    let body = encode_request (resource_spans_of_span_event e ~close_wall_ns) in
    match http_post ~net ~clock ~timeout ~headers ~url ~body with
    | Ok () -> ()
    | Error msg -> raise (Failure msg)
  in
  { Obs_eio.emit_span; emit_metric = (fun _ -> ()); declare_metric = (fun _ -> ()) }
