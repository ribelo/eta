open Eio.Std

type outcome =
  | Accepted
  | Rejected of string

type policy_outcome =
  | Use_crls
  | Reject of string

let policy_version = (`TLS_1_2, `TLS_1_2)

let narrowed_ciphers =
  [
    `ECDHE_RSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_RSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256;
    `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_ECDSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256;
  ]

let quote = Filename.quote

let run_cmd cmd =
  match Sys.command cmd with
  | 0 -> ()
  | code -> failwith (Printf.sprintf "command failed code=%d cmd=%s" code cmd)

let write_file path contents =
  let out = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr out)
    (fun () -> output_string out contents)

let write_binary_file path contents =
  let out = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr out)
    (fun () -> output_string out contents)

let read_binary_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let len = in_channel_length input in
      really_input_string input len)

let mkdir_p path = run_cmd ("mkdir -p " ^ quote path)
let openssl cmd = run_cmd ("openssl " ^ cmd ^ " >/dev/null 2>&1")

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let classify_error exn =
  let error = Printexc.to_string exn in
  if contains ~needle:"revoked" error || contains ~needle:"Revoked" error then
    "reject_revoked"
  else if contains ~needle:"invalid certificate chain" error then
    "reject_invalid_chain"
  else if contains ~needle:"handshake failure" error then "reject_handshake"
  else "reject_other"

let time_exn s =
  match Ptime.of_rfc3339 s with
  | Ok (time, _, _) -> time
  | Error _ -> failwith ("bad time " ^ s)

let policy_time = time_exn "2026-05-23T00:00:00Z"
let fresh_next_update = time_exn "2026-06-01T00:00:00Z"
let stale_next_update = time_exn "2020-01-01T00:00:00Z"
let this_update = time_exn "2026-05-22T00:00:00Z"

let cert_root_name () =
  "h_s3_pivot_revocation_" ^ string_of_int (Unix.getpid ())

let san_config =
  String.concat "\n"
    [
      "[req]";
      "distinguished_name = dn";
      "prompt = no";
      "req_extensions = req_ext";
      "";
      "[dn]";
      "CN = revoked.local.test";
      "";
      "[req_ext]";
      "basicConstraints = critical,CA:FALSE";
      "keyUsage = critical,digitalSignature,keyEncipherment";
      "extendedKeyUsage = serverAuth";
      "subjectAltName = DNS:revoked.local.test";
      "";
    ]

let create_ca root =
  openssl
    (String.concat " "
       [
         "req -x509 -newkey rsa:2048 -nodes";
         "-keyout " ^ quote (Filename.concat root "ca.key");
         "-out " ^ quote (Filename.concat root "ca.pem");
         "-days 30 -sha256";
         "-subj " ^ quote "/CN=Eta H-S3 Pivot Revocation CA";
         "-addext " ^ quote "basicConstraints=critical,CA:TRUE,pathlen:0";
         "-addext " ^ quote "keyUsage=critical,keyCertSign,cRLSign";
       ])

let create_leaf root =
  let cnf = Filename.concat root "leaf.cnf" in
  let key = Filename.concat root "leaf.key" in
  let csr = Filename.concat root "leaf.csr" in
  let pem = Filename.concat root "leaf.pem" in
  write_file cnf san_config;
  openssl
    (String.concat " "
       [
         "req -newkey rsa:2048 -nodes";
         "-keyout " ^ quote key;
         "-out " ^ quote csr;
         "-subj " ^ quote "/CN=revoked.local.test";
         "-config " ^ quote cnf;
       ]);
  openssl
    (String.concat " "
       [
         "x509 -req";
         "-in " ^ quote csr;
         "-CA " ^ quote (Filename.concat root "ca.pem");
         "-CAkey " ^ quote (Filename.concat root "ca.key");
         "-CAcreateserial";
         "-out " ^ quote pem;
         "-days 30 -sha256";
         "-extfile " ^ quote cnf;
         "-extensions req_ext";
       ])

let load_cert path =
  let pem = Cstruct.of_string (read_binary_file path) in
  match X509.Certificate.decode_pem_multiple pem with
  | Ok (cert :: _) -> cert
  | Ok [] -> failwith ("no certificate in " ^ path)
  | Error (`Msg msg) -> failwith msg

let load_private_key path =
  let pem = Cstruct.of_string (read_binary_file path) in
  match X509.Private_key.decode_pem pem with
  | Ok key -> key
  | Error (`Msg msg) -> failwith msg

let prepare () =
  mkdir_p "_build";
  let root_name = cert_root_name () in
  let root = Filename.concat "_build" root_name in
  mkdir_p root;
  create_ca root;
  create_leaf root;
  let ca_cert = load_cert (Filename.concat root "ca.pem") in
  let ca_key = load_private_key (Filename.concat root "ca.key") in
  let leaf = load_cert (Filename.concat root "leaf.pem") in
  let revoked_crl =
    {
      X509.CRL.serial = X509.Certificate.serial leaf;
      date = this_update;
      extensions = X509.Extension.empty;
    }
    |> fun revoked ->
    match
      X509.CRL.revoke ~issuer:(X509.Certificate.subject ca_cert) ~this_update
        ~next_update:fresh_next_update [ revoked ] ca_key
    with
    | Ok crl -> crl
    | Error (`Msg msg) -> failwith msg
  in
  let stale_empty_crl =
    match
      X509.CRL.revoke ~issuer:(X509.Certificate.subject ca_cert) ~this_update
        ~next_update:stale_next_update [] ca_key
    with
    | Ok crl -> crl
    | Error (`Msg msg) -> failwith msg
  in
  let revoked_dir = Filename.concat root "revoked_crls" in
  let stale_dir = Filename.concat root "stale_crls" in
  mkdir_p revoked_dir;
  mkdir_p stale_dir;
  write_binary_file (Filename.concat revoked_dir "revoked.der")
    (Cstruct.to_string (X509.CRL.encode_der revoked_crl));
  write_binary_file (Filename.concat stale_dir "stale.der")
    (Cstruct.to_string (X509.CRL.encode_der stale_empty_crl));
  (root_name, revoked_crl, stale_empty_crl, ca_cert, leaf)

let certchain dir =
  let open Eio.Path in
  X509_eio.private_of_pems ~cert:(dir / "leaf.pem") ~priv_key:(dir / "leaf.key")

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let server_config dir =
  Tls.Config.server ~version:policy_version
    ~certificates:(`Single (certchain dir))
    ~ciphers:narrowed_ciphers ()

let client_config ?crl_dir dir =
  let open Eio.Path in
  let authenticator =
    match crl_dir with
    | None -> X509_eio.authenticator (`Ca_file (dir / "ca.pem"))
    | Some crl_dir ->
        X509_eio.authenticator ~crls:crl_dir (`Ca_file (dir / "ca.pem"))
  in
  Tls.Config.client ~authenticator ~version:policy_version
    ~ciphers:narrowed_ciphers ()

let run_tls ?crl_dir env dir =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_done, resolve_server = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let result =
        try
          Eio.Switch.run @@ fun conn_sw ->
          let raw_flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
          let tls_flow = Tls_eio.server_of_flow (server_config dir) raw_flow in
          Eio.Flow.copy_string "ok" tls_flow;
          Eio.Resource.close tls_flow;
          Ok ()
        with exn -> Error (Printexc.to_string exn)
      in
      ignore (Eio.Promise.try_resolve resolve_server result));
  let outcome =
    try
      Eio.Switch.run @@ fun client_sw ->
      let raw_flow =
        Eio.Net.connect ~sw:client_sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      let tls_flow =
        Tls_eio.client_of_flow
          (client_config ?crl_dir dir)
          ~host:(host_exn "revoked.local.test")
          raw_flow
      in
      Eio.Resource.close tls_flow;
      Accepted
    with exn -> Rejected (classify_error exn)
  in
  ignore (Eio.Promise.await server_done);
  outcome

let revocation_policy = function
  | `Fresh crls ->
      if
        List.exists
          (fun crl ->
            match X509.CRL.next_update crl with
            | None -> false
            | Some next -> Ptime.compare next policy_time < 0)
          crls
      then Reject "reject_stale"
      else Use_crls
  | `Unavailable -> Reject "reject_unavailable"
  | `Unknown -> Reject "reject_unknown"

let revoked_policy ~issuer ~cert crls =
  if X509.CRL.is_revoked ~issuer ~cert crls then Reject "reject_revoked"
  else Use_crls

let print_policy name expected observed =
  let result = if String.equal expected observed then "PASS" else "FAIL" in
  Printf.printf
    "h_s3_pivot_revocation name=%s expected=%s observed=%s result=%s policy=caller_owned_hard_fail\n\
     %!"
    name expected observed result;
  result

let print_tls name expected = function
  | Accepted ->
      let result = if String.equal expected "accepted" then "PASS" else "FAIL" in
      Printf.printf
        "h_s3_pivot_revocation name=%s expected=%s observed=accepted result=%s policy=caller_supplied_crl\n\
         %!"
        name expected result;
      result
  | Rejected observed ->
      let result = if String.equal expected observed then "PASS" else "FAIL" in
      Printf.printf
        "h_s3_pivot_revocation name=%s expected=%s observed=%s result=%s policy=caller_supplied_crl\n\
         %!"
        name expected observed result;
      result

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let root_name, revoked_crl, stale_crl, ca_cert, leaf = prepare () in
  let dir = Eio.Path.(Eio.Stdenv.cwd env / "_build" / root_name) in
  let revoked_dir = Eio.Path.(dir / "revoked_crls") in
  let no_crl = print_tls "no_crl_accepts" "accepted" (run_tls env dir) in
  let revoked_tls =
    print_tls "caller_supplied_crl_rejects" "reject_invalid_chain"
      (run_tls ~crl_dir:revoked_dir env dir)
  in
  let revoked_policy =
    match revoked_policy ~issuer:ca_cert ~cert:leaf [ revoked_crl ] with
    | Reject reason -> print_policy "revoked_policy" "reject_revoked" reason
    | Use_crls -> print_policy "revoked_policy" "reject_revoked" "use_crls"
  in
  let stale_policy =
    match revocation_policy (`Fresh [ stale_crl ]) with
    | Reject reason -> print_policy "stale_crl_policy" "reject_stale" reason
    | Use_crls -> print_policy "stale_crl_policy" "reject_stale" "use_crls"
  in
  let unavailable_policy =
    match revocation_policy `Unavailable with
    | Reject reason ->
        print_policy "unavailable_policy" "reject_unavailable" reason
    | Use_crls ->
        print_policy "unavailable_policy" "reject_unavailable" "use_crls"
  in
  let unknown_policy =
    match revocation_policy `Unknown with
    | Reject reason -> print_policy "unknown_policy" "reject_unknown" reason
    | Use_crls -> print_policy "unknown_policy" "reject_unknown" "use_crls"
  in
  let results =
    [
      no_crl;
      revoked_tls;
      revoked_policy;
      stale_policy;
      unavailable_policy;
      unknown_policy;
    ]
  in
  if List.for_all (String.equal "PASS") results then
    Printf.printf
      "h_s3_pivot_revocation_summary verdict=PASS failed=<none> policy=caller_owned_hard_fail\n\
       %!"
  else
    Printf.printf
      "h_s3_pivot_revocation_summary verdict=FAIL failed=<see-above> policy=caller_owned_hard_fail\n\
       %!"
