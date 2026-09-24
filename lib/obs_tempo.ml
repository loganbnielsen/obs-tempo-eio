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

let resource_spans_of_span_event (e : Obs_eio.span_event) ~close_wall_ns =
  let start_time_unix_nano =
    Int64.sub close_wall_ns (Int64.sub e.end_ns e.start_ns)
  in
  let span =
    Trace.make_span
      ~trace_id:(trace_id_bytes e.trace_ctx.Obs_trace.trace_id)
      ~span_id:(span_id_bytes e.trace_ctx.Obs_trace.span_id)
      ?parent_span_id:(Option.map span_id_bytes e.parent_span_id)
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
  let request = Trace_service.make_export_trace_service_request ~resource_spans () in
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

(* ------------------------------------------------------------------ *)
(* Asynchronous export (0.2)                                           *)
(* ------------------------------------------------------------------ *)

(* Same design as obs-loki-eio 0.2 (its [Obs_loki.create] carries the full
   rationale): [emit_span] only encodes and enqueues; a background fiber on
   [sw] exports in batches, so a slow or unreachable Tempo never blocks the
   fiber that closed a span (Sol OBS-048). The [Stdlib.Mutex] guards queue
   operations only and is never held across a yield. *)
type t = {
  backend : Obs_eio.backend;
  flush : float -> unit;
  dropped : int Atomic.t;
}

let backend t = t.backend
let dropped t = Atomic.get t.dropped
let flush ?(timeout = 5.0) t = t.flush timeout

let create ~sw ~net ~clock ~url ?(timeout = 5.0) ?(headers = []) ?(max_queued = 10_000)
    ?(max_batch = 500) () : t =
  if timeout <= 0. || classify_float timeout = FP_nan then
    invalid_arg "Obs_tempo.create: timeout must be positive";
  if max_queued < 1 then invalid_arg "Obs_tempo.create: max_queued must be positive";
  if max_batch < 1 then invalid_arg "Obs_tempo.create: max_batch must be positive";
  validate_url url;
  let queue = Queue.create () in
  let queue_mutex = Mutex.create () in
  let in_flight = Atomic.make 0 in
  let dropped = Atomic.make 0 in
  let wake = Eio.Condition.create () in
  let with_queue f =
    Mutex.lock queue_mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock queue_mutex) f
  in
  let enqueue item =
    with_queue (fun () ->
      if Queue.length queue >= max_queued then begin
        ignore (Queue.take queue);
        Atomic.incr dropped
      end;
      Queue.add item queue);
    Eio.Condition.broadcast wake
  in
  let take_batch () =
    with_queue (fun () ->
      let rec go n acc =
        if n = 0 || Queue.is_empty queue then List.rev acc
        else go (n - 1) (Queue.take queue :: acc)
      in
      let batch = go max_batch [] in
      if batch <> [] then Atomic.incr in_flight;
      batch)
  in
  let last_report = ref neg_infinity in
  let report_failure ~spans msg =
    let now = Eio.Time.now clock in
    if now -. !last_report >= 10. then begin
      last_report := now;
      Printf.eprintf "[obs-tempo] export failed, %d span(s) lost: %s (dropped so far: %d)\n%!"
        spans msg (Atomic.get dropped)
    end
  in
  let push batch =
    Fun.protect ~finally:(fun () -> Atomic.decr in_flight) (fun () ->
      match http_post ~net ~clock ~timeout ~headers ~url ~body:(encode_request batch) with
      | Ok () -> ()
      | Error msg -> report_failure ~spans:(List.length batch) msg)
  in
  let rec drain () =
    match take_batch () with
    | [] ->
      Eio.Fiber.first
        (fun () -> Eio.Condition.await_no_mutex wake)
        (fun () -> Eio.Time.sleep clock 1.0);
      drain ()
    | batch -> push batch; drain ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () -> drain ());
  let flush timeout =
    let deadline = Eio.Time.now clock +. timeout in
    let rec go () =
      match take_batch () with
      | [] ->
        if Atomic.get in_flight > 0 && Eio.Time.now clock < deadline then begin
          Eio.Time.sleep clock 0.01; go ()
        end
      | batch -> push batch; if Eio.Time.now clock < deadline then go ()
    in
    go ()
  in
  let emit_span (e : Obs_eio.span_event) =
    let close_wall_ns = wall_now_ns clock in
    enqueue (resource_spans_of_span_event e ~close_wall_ns)
  in
  { backend = { Obs_eio.emit_span; emit_metric = (fun _ -> ()); declare_metric = (fun _ -> ()) };
    flush; dropped }
