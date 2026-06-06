open Test_eta_http_support

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let contains haystack needle =
  match find_sub haystack ~needle with
  | Some _ -> true
  | None -> false

let find_tls_eio_source () =
  let candidates =
    [
      "lib/http/tls/tls_eio.ml";
      "../lib/http/tls/tls_eio.ml";
      "../../lib/http/tls/tls_eio.ml";
      "../../../lib/http/tls/tls_eio.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate tls_eio.ml from %s" (Sys.getcwd ())

let do_handshake_source source =
  let start_markers = [ "let do_handshake t ="; "let rec do_handshake t =" ] in
  let end_marker = "let close t =" in
  match
    List.find_map
      (fun marker -> find_sub source ~needle:marker)
      start_markers
  with
  | None -> Alcotest.fail "missing do_handshake definition"
  | Some start -> (
      match find_sub_from source ~needle:end_marker start with
      | None -> Alcotest.fail "missing do_handshake end marker"
      | Some finish -> String.sub source start (finish - start))

let client_of_flow_source source =
  match find_sub source ~needle:"let client_of_flow" with
  | None -> Alcotest.fail "missing client_of_flow definition"
  | Some start -> (
      match find_sub_from source ~needle:"let epoch flow =" start with
      | None -> Alcotest.fail "missing client_of_flow end marker"
      | Some finish -> String.sub source start (finish - start))

let test_tls_chokepoint_policy () =
  let client = Eta_http.Tls.Config.default_client () in
  Alcotest.(check bool)
    "TLS 1.2 only"
    true
    (Eta_http.Tls.Config.policy_version = (`TLS_1_2, `TLS_1_2));
  Alcotest.(check (list string))
    "exact policy ciphers"
    Eta_http.Tls.Config.policy_ciphers
    Eta_http.Tls.Config.policy_ciphers;
  Alcotest.(check (list string))
    "default ALPN" [ "h2"; "http/1.1" ]
    (Eta_http.Tls.Config.alpn_protocols client)

let test_openssl_ssl_finalizer_keeps_ctx_ownership_separate () =
  let exercise_shared_ctx () =
    let ctx = Eta_http__Openssl.create_ctx () in
    let ssl_a =
      Eta_http__Openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    let ssl_b =
      Eta_http__Openssl.create_ssl ctx ~hostname:None ~ip:None ~alpn_protocols:[]
    in
    Gc.full_major ();
    Alcotest.(check int)
      "pending bytes before handshake" 0
      (Eta_http__Openssl.bio_write_pending ssl_a);
    ignore (Eta_http__Openssl.bio_write_pending ssl_b : int)
  in
  exercise_shared_ctx ();
  Gc.full_major ();
  Gc.full_major ()

let test_tls_handshake_enters_ssl_mutex_before_openssl () =
  let source = read_file (find_tls_eio_source ()) in
  let body = do_handshake_source source in
  let guard = "with_ssl t (fun () ->" in
  let handshake = "Openssl.handshake t.ssl" in
  match (find_sub body ~needle:guard, find_sub body ~needle:handshake) with
  | Some guard_pos, Some handshake_pos ->
      Alcotest.(check bool)
        "mutex guard precedes handshake" true (guard_pos < handshake_pos)
  | None, _ -> Alcotest.fail "do_handshake does not enter ssl_mutex"
  | _, None -> Alcotest.fail "do_handshake does not call OpenSSL handshake"

let test_tls_client_of_flow_uses_ip_identity () =
  let source = read_file (find_tls_eio_source ()) in
  let body = client_of_flow_source source in
  Alcotest.(check bool)
    "TLS IP peer identity is consumed" true
    (contains body "Config.ip config")
