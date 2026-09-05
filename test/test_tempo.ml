(** obs-eio-tempo tests.

    Mock-server tests run without any external infrastructure: they decode
    the exact OTLP protobuf payload sent to Tempo using the same
    [opentelemetry] package the backend uses to build it, so a round-trip
    through the real wire encoder/decoder is exercised, not just string
    matching.

    Live Tempo tests require [TEMPO_URL] (OTLP/HTTP ingestion, e.g.
    [http://localhost:4318]) and [TEMPO_QUERY_URL] (Tempo's query API, e.g.
    [http://localhost:3200] — a different port than ingestion in Tempo's
    real deployment shape) and are marked [Slow]. They push a span and query
    it back by trace id to confirm ingestion. *)

module Trace = Opentelemetry.Proto.Trace
module Resource = Opentelemetry.Proto.Resource
module Common = Opentelemetry.Proto.Common
module Trace_service = Opentelemetry.Proto.Trace_service

(* ------------------------------------------------------------------ *)
(* Mock Tempo server (cohttp-eio)                                      *)
(* ------------------------------------------------------------------ *)

(* Mock OTLP/HTTP receiver on an ephemeral port: accepts one POST, captures
   the raw protobuf body, responds with [status_code], then stops. *)
let with_mock_tempo_server env ?(status_code = 200) f =
  Eio.Switch.run @@ fun sw ->
  let body_p, body_r = Eio.Promise.create () in
  let stop, stop_r = Eio.Promise.create () in
  let callback _conn _req body =
    let captured =
      let buf = Eio.Buf_read.of_flow body ~max_size:(256 * 1024) in
      Eio.Buf_read.take_all buf
    in
    (if not (Eio.Promise.is_resolved body_p) then
       Eio.Promise.resolve body_r captured);
    Cohttp_eio.Server.respond
      ~status:(Http.Status.of_int status_code)
      ~body:(Cohttp_eio.Body.of_string "")
      ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  match Eio.Net.listen ~backlog:5 ~sw env#net addr with
  | exception Unix.Unix_error (Unix.EPERM, "bind", _) ->
    (* Some sandboxed CI environments (e.g. opam-repository's macOS build
       sandbox) forbid binding even a loopback socket. *)
    Printf.printf "[skip] sandboxed environment forbids binding a local socket\n%!"
  | socket ->
    let port =
      Eio.Net.listening_addr socket
      |> function `Tcp (_, p) -> p | _ -> failwith "unexpected addr"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
      `Stop_daemon);
    let result = f ~port ~body_promise:body_p in
    Eio.Promise.resolve stop_r ();
    result

let local_url port = Printf.sprintf "http://127.0.0.1:%d" port

let contains s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then true
  else if ls < lp then false
  else begin
    let rec go i =
      if i > ls - lp then false
      else if String.sub s i lp = sub then true
      else go (i + 1)
    in
    go 0
  end

(* ------------------------------------------------------------------ *)
(* Payload decoding helpers                                            *)
(* ------------------------------------------------------------------ *)

let decode_request body : Trace_service.export_trace_service_request =
  Trace_service.decode_pb_export_trace_service_request (Pbrt.Decoder.of_string body)

let the_span (req : Trace_service.export_trace_service_request) : Trace.span =
  match req.resource_spans with
  | [ ({ scope_spans = [ { spans = [ span ]; _ } ]; _ } : Trace.resource_spans) ] -> span
  | _ -> Alcotest.fail "expected exactly one resource_spans/scope_spans/span"

let the_resource (req : Trace_service.export_trace_service_request) : Resource.resource =
  match req.resource_spans with
  | [ ({ resource = Some r; _ } : Trace.resource_spans) ] -> r
  | _ -> Alcotest.fail "expected a resource on the single resource_spans entry"

let attr_string (attrs : Common.key_value list) key =
  List.find_map
    (fun (kv : Common.key_value) ->
      if kv.key = key then
        match kv.value with
        | Some (Common.String_value v) -> Some v
        | _ -> None
      else None)
    attrs

let hex_of_bytes b =
  String.concat "" (List.map (Printf.sprintf "%02x") (List.init (Bytes.length b) (Bytes.get_uint8 b)))

(* ------------------------------------------------------------------ *)
(* Mock server tests                                                   *)
(* ------------------------------------------------------------------ *)

let test_resource_contains_service_name () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"test-svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    Obs_eio.with_span ot "op" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let req = decode_request body in
    let resource = the_resource req in
    Alcotest.(check (option string))
      "service.name resource attribute present"
      (Some "test-svc")
      (attr_string resource.attributes "service.name"))

let test_span_name_and_ok_status () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    Obs_eio.with_span ot "my-span-name" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    Alcotest.(check string) "span name" "my-span-name" span.name;
    match span.status with
    | Some { code = Trace.Status_code_ok; _ } -> ()
    | _ -> Alcotest.fail "expected Status_code_ok")

let test_span_error_status_carries_message () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    (try
       Obs_eio.with_span ot "failing-op" (fun _sp -> failwith "boom")
     with Failure _ -> ());
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    match span.status with
    | Some { code = Trace.Status_code_error; message; _ } ->
      Alcotest.(check bool) "message mentions boom" true (contains message "boom")
    | _ -> Alcotest.fail "expected Status_code_error")

let test_log_entries_become_span_events () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    Obs_eio.with_span ot "work" (fun sp ->
      Obs_eio.log sp Obs_eio.Info ~fields:[ ("key", "val") ] "my-unique-message");
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    match span.events with
    | [ (event : Trace.span_event) ] ->
      Alcotest.(check string) "event name is log message" "my-unique-message" event.name;
      Alcotest.(check (option string)) "level attribute present"
        (Some "info") (attr_string event.attributes "level");
      Alcotest.(check (option string)) "user field present"
        (Some "val") (attr_string event.attributes "key")
    | _ -> Alcotest.fail "expected exactly one span event")

let test_span_with_no_logs_has_no_events () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    Obs_eio.with_span ot "quiet-op" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    Alcotest.(check int) "no span events" 0 (List.length span.events))

let test_context_fields_become_resource_attributes () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    let ot = Obs_eio.with_context ot [ ("env", "prod"); ("region", "eu-west-1") ] in
    Obs_eio.with_span ot "op" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let resource = the_resource (decode_request body) in
    Alcotest.(check (option string)) "env attribute" (Some "prod")
      (attr_string resource.attributes "env");
    Alcotest.(check (option string)) "region attribute" (Some "eu-west-1")
      (attr_string resource.attributes "region"))

let test_trace_id_and_span_id_round_trip () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    let captured_trace_id = ref "" and captured_span_id = ref "" in
    Obs_eio.with_span ot "trace-test" (fun sp ->
      let ctx = Obs_eio.current_trace_context sp in
      let hi, lo = ctx.Obs_trace.trace_id in
      captured_trace_id := Printf.sprintf "%016Lx%016Lx" hi lo;
      captured_span_id := Printf.sprintf "%016Lx" ctx.Obs_trace.span_id);
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    Alcotest.(check string) "trace_id matches" !captured_trace_id (hex_of_bytes span.trace_id);
    Alcotest.(check string) "span_id matches" !captured_span_id (hex_of_bytes span.span_id))

let test_parent_span_id_maps_to_otlp () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    let parent = Obs_trace.generate () in
    Obs_eio.with_span ot ~parent "child" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    Alcotest.(check string) "parent_span_id is the parent context's span_id"
      (Printf.sprintf "%016Lx" parent.Obs_trace.span_id)
      (hex_of_bytes span.parent_span_id))

let test_root_span_has_no_parent_span_id () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env (fun ~port ~body_promise ->
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo () in
    Obs_eio.with_span ot "root" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    let span = the_span (decode_request body) in
    Alcotest.(check bool) "no parent_span_id on a root span" true (Bytes.length span.parent_span_id = 0))

let test_create_rejects_invalid_timeout () =
  Eio_main.run @@ fun env ->
  match Obs_tempo.create ~net:env#net ~clock:env#clock ~url:"http://127.0.0.1:4318" ~timeout:0. () with
  | _ -> Alcotest.fail "non-positive timeout should raise Invalid_argument"
  | exception Invalid_argument _ -> ()

let test_create_rejects_invalid_url () =
  Eio_main.run @@ fun env ->
  match Obs_tempo.create ~net:env#net ~clock:env#clock ~url:"unix:/tmp/tempo.sock" () with
  | _ -> Alcotest.fail "non-http URL should raise Invalid_argument"
  | exception Invalid_argument _ -> ()

let test_tempo_unreachable_reports_backend_error () =
  Eio_main.run @@ fun env ->
  let reported = ref None in
  let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:"http://127.0.0.1:19398" () in
  let ot =
    Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo
      ~on_backend_error:(fun op exn -> reported := Some (op, Printexc.to_string exn))
      ()
  in
  Obs_eio.with_span ot "op" (fun _sp -> ());
  match !reported with
  | Some (Obs_eio.Emit_span { name }, msg) ->
    Alcotest.(check string) "span name" "op" name;
    Alcotest.(check bool) "tempo failure reported" true (contains msg "Tempo push")
  | _ -> Alcotest.fail "expected Tempo push failure to reach on_backend_error"

let test_non_2xx_reports_backend_error () =
  Eio_main.run @@ fun env ->
  with_mock_tempo_server env ~status_code:500 (fun ~port ~body_promise:_ ->
    let reported = ref None in
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:(local_url port) () in
    let ot =
      Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:tempo
        ~on_backend_error:(fun op exn -> reported := Some (op, Printexc.to_string exn))
        ()
    in
    Obs_eio.with_span ot "op" (fun _sp -> ());
    match !reported with
    | Some (Obs_eio.Emit_span { name }, msg) ->
      Alcotest.(check string) "span name" "op" name;
      Alcotest.(check bool) "status reported" true (contains msg "Tempo returned HTTP 500")
    | _ -> Alcotest.fail "expected non-2xx Tempo response to reach on_backend_error")

(* ------------------------------------------------------------------ *)
(* Live Tempo tests (require TEMPO_URL / TEMPO_QUERY_URL env vars)     *)
(* ------------------------------------------------------------------ *)

let tempo_get_trace ~net ~url ~trace_id_hex =
  let uri = Uri.of_string (url ^ "/api/traces/" ^ trace_id_hex) in
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run @@ fun sw ->
  let hdrs = Http.Header.of_list [ ("Accept", "application/json") ] in
  let resp, body = Cohttp_eio.Client.call client ~sw ~headers:hdrs `GET uri in
  let status = Http.Response.status resp |> Http.Status.to_int in
  let text = Eio.Buf_read.(parse_exn take_all) body ~max_size:(1024 * 1024) in
  (status, text)

(* Tempo's query API returns Tempo's own OTLP-JSON trace shape (a
   [{"batches": [<OTLP ResourceSpans as JSON>, ...]}] envelope) — walk down
   to the span-event names to confirm our marker actually round-tripped
   through Tempo, not just that some 200 body came back. *)
let queried_span_event_names json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields ->
    (match List.assoc_opt "batches" fields with
     | Some (`List batches) ->
       List.concat_map
         (function
           | `Assoc batch ->
             (match List.assoc_opt "scopeSpans" batch with
              | Some (`List scope_spans) ->
                List.concat_map
                  (function
                    | `Assoc ss ->
                      (match List.assoc_opt "spans" ss with
                       | Some (`List spans) ->
                         List.concat_map
                           (function
                             | `Assoc span ->
                               (match List.assoc_opt "events" span with
                                | Some (`List events) ->
                                  List.filter_map
                                    (function
                                      | `Assoc event ->
                                        (match List.assoc_opt "name" event with
                                         | Some (`String n) -> Some n
                                         | _ -> None)
                                      | _ -> None)
                                    events
                                | _ -> [])
                             | _ -> [])
                           spans
                       | _ -> [])
                    | _ -> [])
                  scope_spans
              | _ -> [])
           | _ -> [])
         batches
     | _ -> [])
  | _ -> []

let test_live_ingestion () =
  match (Sys.getenv_opt "TEMPO_URL", Sys.getenv_opt "TEMPO_QUERY_URL") with
  | None, _ | _, None ->
    Printf.printf "[skip] TEMPO_URL/TEMPO_QUERY_URL not set — skipping live Tempo ingestion test\n%!"
  | Some tempo_url, Some tempo_query_url ->
    Eio_main.run @@ fun env ->
    let unique_service = Printf.sprintf "tempo-e2e-test-%d" (int_of_float (Unix.gettimeofday ())) in
    let tempo = Obs_tempo.create ~net:env#net ~clock:env#clock ~url:tempo_url () in
    let ot = Obs_eio.create ~service:unique_service ~mono_clock:env#mono_clock ~backend:tempo () in
    let captured_trace_id = ref "" in
    Obs_eio.with_span ot "e2e-span" (fun sp ->
      let ctx = Obs_eio.current_trace_context sp in
      let hi, lo = ctx.Obs_trace.trace_id in
      captured_trace_id := Printf.sprintf "%016Lx%016Lx" hi lo;
      Obs_eio.log sp Obs_eio.Info ~fields:[ ("check", "ingestion") ] "tempo-e2e-marker");
    let deadline = Unix.gettimeofday () +. 10.0 in
    let found = ref false in
    while (not !found) && Unix.gettimeofday () < deadline do
      Eio.Time.sleep env#clock 0.5;
      match tempo_get_trace ~net:env#net ~url:tempo_query_url ~trace_id_hex:!captured_trace_id with
      | 200, body when String.length body > 0 ->
        found := List.mem "tempo-e2e-marker" (queried_span_event_names body)
      | _ -> ()
    done;
    Alcotest.(check bool) "marker log entry queryable back out of Tempo" true !found

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "obs_tempo" [
    "payload", [
      test_case "resource contains service.name"       `Quick test_resource_contains_service_name;
      test_case "span name and ok status"               `Quick test_span_name_and_ok_status;
      test_case "error status carries message"          `Quick test_span_error_status_carries_message;
      test_case "log entries become span events"        `Quick test_log_entries_become_span_events;
      test_case "span with no logs has no events"       `Quick test_span_with_no_logs_has_no_events;
      test_case "context fields become resource attrs"  `Quick test_context_fields_become_resource_attributes;
      test_case "trace_id/span_id round trip"            `Quick test_trace_id_and_span_id_round_trip;
      test_case "parent_span_id maps to OTLP"            `Quick test_parent_span_id_maps_to_otlp;
      test_case "root span has no parent_span_id"        `Quick test_root_span_has_no_parent_span_id;
      test_case "invalid timeout rejected"                `Quick test_create_rejects_invalid_timeout;
      test_case "invalid URL rejected"                    `Quick test_create_rejects_invalid_url;
      test_case "unreachable Tempo reports backend error" `Quick test_tempo_unreachable_reports_backend_error;
      test_case "non-2xx response reports backend error"  `Quick test_non_2xx_reports_backend_error;
    ];
    "live", [
      test_case "span ingested and queryable" `Slow test_live_ingestion;
    ];
  ]
