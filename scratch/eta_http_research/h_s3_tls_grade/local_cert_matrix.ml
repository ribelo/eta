open Eio.Std

type expected =
  | Accept
  | Reject_name

type identity =
  | Host of string
  | Ip of string

type server_certs =
  | Single of string
  | Multiple_default of
      { default : string
      ; alternatives : string list
      }

type tls_version = [ `TLS_1_0 | `TLS_1_1 | `TLS_1_2 | `TLS_1_3 ]

type row =
  { name : string
  ; certs : server_certs
  ; identity : identity
  ; version : tls_version * tls_version
  ; expected : expected
  }

type outcome =
  | Accepted of
      { version : string
      ; payload : string
      }
  | Rejected of string

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

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

let mkdir_p path =
  run_cmd ("mkdir -p " ^ quote path)

let openssl cmd =
  run_cmd ("openssl " ^ cmd ^ " >/dev/null 2>&1")

let cert_root_name () =
  "h_s3_local_cert_matrix_" ^ string_of_int (Unix.getpid ())

let san_config ~cn ~dns ~ips =
  let dns_lines =
    List.mapi
      (fun i name -> Printf.sprintf "DNS.%d = %s" (i + 1) name)
      dns
  in
  let ip_lines =
    List.mapi (fun i ip -> Printf.sprintf "IP.%d = %s" (i + 1) ip) ips
  in
  String.concat
    "\n"
    ([ "[req]"
     ; "distinguished_name = dn"
     ; "prompt = no"
     ; "req_extensions = req_ext"
     ; ""
     ; "[dn]"
     ; "CN = " ^ cn
     ; ""
     ; "[req_ext]"
     ; "basicConstraints = critical,CA:FALSE"
     ; "keyUsage = critical,digitalSignature,keyEncipherment"
     ; "extendedKeyUsage = serverAuth"
     ; "subjectAltName = @alt_names"
     ; ""
     ; "[alt_names]"
     ]
     @ dns_lines
     @ ip_lines
     @ [ "" ])

let create_ca root =
  openssl
    (String.concat
       " "
       [ "req -x509 -newkey rsa:2048 -nodes"
       ; "-keyout " ^ quote (Filename.concat root "ca.key")
       ; "-out " ^ quote (Filename.concat root "ca.pem")
       ; "-days 30 -sha256"
       ; "-subj " ^ quote "/CN=Eta H-S3 Test CA"
       ; "-addext " ^ quote "basicConstraints=critical,CA:TRUE,pathlen:0"
       ; "-addext " ^ quote "keyUsage=critical,keyCertSign,cRLSign"
       ])

let create_leaf root ~name ~cn ~dns ~ips =
  let cnf = Filename.concat root (name ^ ".cnf") in
  let key = Filename.concat root (name ^ ".key") in
  let csr = Filename.concat root (name ^ ".csr") in
  let pem = Filename.concat root (name ^ ".pem") in
  write_file cnf (san_config ~cn ~dns ~ips);
  openssl
    (String.concat
       " "
       [ "req -newkey rsa:2048 -nodes"
       ; "-keyout " ^ quote key
       ; "-out " ^ quote csr
       ; "-subj " ^ quote ("/CN=" ^ cn)
       ; "-config " ^ quote cnf
       ]);
  openssl
    (String.concat
       " "
       [ "x509 -req"
       ; "-in " ^ quote csr
       ; "-CA " ^ quote (Filename.concat root "ca.pem")
       ; "-CAkey " ^ quote (Filename.concat root "ca.key")
       ; "-CAcreateserial"
       ; "-out " ^ quote pem
       ; "-days 30 -sha256"
       ; "-extfile " ^ quote cnf
       ; "-extensions req_ext"
       ])

let prepare_certs () =
  mkdir_p "_build";
  let root_name = cert_root_name () in
  let root = Filename.concat "_build" root_name in
  mkdir_p root;
  create_ca root;
  create_leaf
    root
    ~name:"single"
    ~cn:"api.local.test"
    ~dns:[ "api.local.test" ]
    ~ips:[];
  create_leaf
    root
    ~name:"wildcard"
    ~cn:"*.wild.local.test"
    ~dns:[ "*.wild.local.test" ]
    ~ips:[];
  create_leaf
    root
    ~name:"multi"
    ~cn:"api.local.test"
    ~dns:[ "api.local.test"; "multi.local.test" ]
    ~ips:[];
  create_leaf root ~name:"ip" ~cn:"127.0.0.1" ~dns:[] ~ips:[ "127.0.0.1" ];
  create_leaf
    root
    ~name:"idna"
    ~cn:"xn--bcher-kva.local.test"
    ~dns:[ "xn--bcher-kva.local.test" ]
    ~ips:[];
  create_leaf
    root
    ~name:"default"
    ~cn:"default.local.test"
    ~dns:[ "default.local.test" ]
    ~ips:[];
  create_leaf
    root
    ~name:"sni"
    ~cn:"sni.local.test"
    ~dns:[ "sni.local.test" ]
    ~ips:[];
  root_name

let certchain dir name =
  let open Eio.Path in
  X509_eio.private_of_pems
    ~cert:(dir / (name ^ ".pem"))
    ~priv_key:(dir / (name ^ ".key"))

let own_cert dir = function
  | Single name -> `Single (certchain dir name)
  | Multiple_default { default; alternatives } ->
    let default = certchain dir default in
    let alternatives = List.map (certchain dir) alternatives in
    `Multiple_default (default, alternatives)

let server_config dir row =
  Tls.Config.server
    ~version:row.version
    ~certificates:(own_cert dir row.certs)
    ~ciphers:Tls.Config.Ciphers.http2
    ()

let client_config dir row =
  let open Eio.Path in
  let authenticator = X509_eio.authenticator (`Ca_file (dir / "ca.pem")) in
  match row.identity with
  | Host _ ->
    Tls.Config.client
      ~authenticator
      ~version:row.version
      ~ciphers:Tls.Config.Ciphers.http2
      ()
  | Ip ip ->
    Tls.Config.client
      ~authenticator
      ~version:row.version
      ~ciphers:Tls.Config.Ciphers.http2
      ~ip:(Ipaddr.of_string_exn ip)
      ()

let tls_epoch_version flow =
  match Tls_eio.epoch flow with
  | Ok epoch -> string_of_tls_version epoch.Tls.Core.protocol_version
  | Error () -> failwith "TLS epoch unavailable"

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
  if
    contains ~needle:"does not contain the name" error
    || contains ~needle:"does not contain the IP" error
  then "reject_name"
  else "reject_other"

let connect_client net dir row port =
  Eio.Switch.run @@ fun sw ->
  let raw_flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let config = client_config dir row in
  let tls_flow =
    match row.identity with
    | Host host -> Tls_eio.client_of_flow config ~host:(host_exn host) raw_flow
    | Ip _ -> Tls_eio.client_of_flow config raw_flow
  in
  let version = tls_epoch_version tls_flow in
  let buf = Cstruct.create 2 in
  let n = Eio.Flow.single_read tls_flow buf in
  let payload = Cstruct.to_string (Cstruct.sub buf 0 n) in
  Eio.Resource.close tls_flow;
  Accepted { version; payload }

let run_row env dir row =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:1
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let server_done, resolve_server = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      try
        Eio.Switch.run @@ fun conn_sw ->
        let raw_flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
        let tls_flow = Tls_eio.server_of_flow (server_config dir row) raw_flow in
        Eio.Flow.copy_string "ok" tls_flow;
        Eio.Resource.close tls_flow;
        Ok ()
      with exn -> Error (Printexc.to_string exn)
    in
    ignore (Eio.Promise.try_resolve resolve_server result));
  let outcome =
    try connect_client net dir row port with
    | exn -> Rejected (classify_error exn)
  in
  ignore (Eio.Promise.await server_done);
  outcome

let string_of_identity = function
  | Host host -> "host:" ^ host
  | Ip ip -> "ip:" ^ ip

let observed_of_outcome = function
  | Accepted _ -> "accepted"
  | Rejected class_ -> class_

let expected_label = function
  | Accept -> "accept"
  | Reject_name -> "reject_name"

let matches = function
  | Accept, Accepted { payload = "ok"; _ } -> true
  | Accept, Accepted _ -> false
  | Accept, Rejected _ -> false
  | Reject_name, Rejected "reject_name" -> true
  | Reject_name, _ -> false

let rows =
  [ { name = "san_single"
    ; certs = Single "single"
    ; identity = Host "api.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "san_mismatch"
    ; certs = Single "single"
    ; identity = Host "other.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Reject_name
    }
  ; { name = "wildcard"
    ; certs = Single "wildcard"
    ; identity = Host "api.wild.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "wildcard_too_deep"
    ; certs = Single "wildcard"
    ; identity = Host "deep.api.wild.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Reject_name
    }
  ; { name = "san_multiple"
    ; certs = Single "multi"
    ; identity = Host "multi.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "ip_literal"
    ; certs = Single "ip"
    ; identity = Ip "127.0.0.1"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "idna_alabel"
    ; certs = Single "idna"
    ; identity = Host "xn--bcher-kva.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "sni_multiple_cert_select"
    ; certs = Multiple_default { default = "default"; alternatives = [ "sni" ] }
    ; identity = Host "sni.local.test"
    ; version = (`TLS_1_2, `TLS_1_3)
    ; expected = Accept
    }
  ; { name = "tls12_only"
    ; certs = Single "single"
    ; identity = Host "api.local.test"
    ; version = (`TLS_1_2, `TLS_1_2)
    ; expected = Accept
    }
  ; { name = "tls13_only"
    ; certs = Single "single"
    ; identity = Host "api.local.test"
    ; version = (`TLS_1_3, `TLS_1_3)
    ; expected = Accept
    }
  ]

let () =
  Eio_main.run @@ fun env ->
  let root_name = prepare_certs () in
  let dir = Eio.Path.(Eio.Stdenv.cwd env / "_build" / root_name) in
  let failures =
    List.filter_map
      (fun row ->
        let outcome = run_row env dir row in
        let result =
          if matches (row.expected, outcome) then "PASS" else "FAIL"
        in
        (match outcome with
         | Accepted { version; payload } ->
           Printf.printf
             "h_s3_local_cert name=%s expected=%s observed=%s result=%s identity=%s version=%s payload=%S\n%!"
             row.name
             (expected_label row.expected)
             (observed_of_outcome outcome)
             result
             (string_of_identity row.identity)
             version
             payload
         | Rejected class_ ->
           Printf.printf
             "h_s3_local_cert name=%s expected=%s observed=%s result=%s identity=%s detail=%S\n%!"
             row.name
             (expected_label row.expected)
             (observed_of_outcome outcome)
             result
             (string_of_identity row.identity)
             class_);
        if result = "PASS" then None else Some row.name)
      rows
  in
  match failures with
  | [] -> Printf.printf "h_s3_local_cert_summary verdict=PASS failed=<none>\n%!"
  | failures ->
    Printf.printf
      "h_s3_local_cert_summary verdict=FAIL failed=%s\n%!"
      (String.concat "," failures)
