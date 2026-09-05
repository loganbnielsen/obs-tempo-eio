(lang dune 3.0)
(name obs-tempo-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name obs-tempo-eio)
 (synopsis "Tempo OTLP/HTTP trace backend for obs-eio")
 (description "\
Converts obs-eio span events into OTLP ResourceSpans and pushes them to Tempo's
OTLP/HTTP trace-ingestion endpoint when each span closes. Not a general-purpose
OTLP client: it is the Tempo backend for obs-eio's Obs_eio.backend interface.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/obs-tempo-eio")
 (bug_reports "https://github.com/loganbnielsen/obs-tempo-eio/issues")
 (source (github loganbnielsen/obs-tempo-eio))
 (depends
  (ocaml (>= 5.4.0))
  (obs-eio (>= 0.1.2))
  (eio (>= 1.3))
  (eio_main (and (>= 1.3) :with-test))
  (opentelemetry (>= 0.91.0))
  (pbrt (>= 4.0))
  (uri (>= 4.4.0))
  (https-eio (>= 0.1.1))
  (cohttp-eio (and (>= 6.2.0) :with-test))
  (http (and (>= 6.0.0) :with-test))
  (yojson (and (>= 3.0.0) :with-test))
  (alcotest :with-test)
  (odoc :with-doc)))
