(** Local CA and server certificate generation using openssl. *)

open Eio.Std

let ( let* ) = Result.bind
let quote = Filename.quote

let run_cmd cmd =
  match Sys.command (cmd ^ " >/dev/null 2>&1") with
  | 0 -> Ok ()
  | code -> Error (Printf.sprintf "openssl command failed code=%d" code)

let write_file path contents =
  let out = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr out)
    (fun () -> output_string out contents)

let mkdir_p path =
  ignore (Sys.command ("mkdir -p " ^ quote path))

let san_config ~cn ~dns ~ips =
  let dns_lines =
    List.mapi (fun i name -> Printf.sprintf "DNS.%d = %s" (i + 1) name) dns
  in
  let ip_lines =
    List.mapi (fun i ip -> Printf.sprintf "IP.%d = %s" (i + 1) ip) ips
  in
  String.concat "\n"
    ([ "[req]";
       "distinguished_name = dn";
       "prompt = no";
       "req_extensions = req_ext";
       "";
       "[dn]";
       "CN = " ^ cn;
       "";
       "[req_ext]";
       "basicConstraints = critical,CA:FALSE";
       "keyUsage = critical,digitalSignature,keyEncipherment";
       "extendedKeyUsage = serverAuth";
       "subjectAltName = @alt_names";
       "";
       "[alt_names]";
     ]
    @ dns_lines @ ip_lines @ [ "" ])

let create_ca root =
  run_cmd
    (String.concat " "
       [
         "openssl req -x509 -newkey rsa:2048 -nodes";
         "-keyout " ^ quote (Filename.concat root "ca.key");
         "-out " ^ quote (Filename.concat root "ca.pem");
         "-days 30 -sha256";
         "-subj " ^ quote "/CN=Eta HTTP Testsuite CA";
         "-addext " ^ quote "basicConstraints=critical,CA:TRUE,pathlen:0";
         "-addext " ^ quote "keyUsage=critical,keyCertSign,cRLSign";
       ])

let create_leaf root ~name ~cn ~dns ~ips =
  let cnf = Filename.concat root (name ^ ".cnf") in
  let key = Filename.concat root (name ^ ".key") in
  let csr = Filename.concat root (name ^ ".csr") in
  let pem = Filename.concat root (name ^ ".pem") in
  write_file cnf (san_config ~cn ~dns ~ips);
  let* () =
    run_cmd
      (String.concat " "
         [
           "openssl req -newkey rsa:2048 -nodes";
           "-keyout " ^ quote key;
           "-out " ^ quote csr;
           "-subj " ^ quote ("/CN=" ^ cn);
           "-config " ^ quote cnf;
         ])
  in
  run_cmd
    (String.concat " "
       [
         "openssl x509 -req";
         "-in " ^ quote csr;
         "-CA " ^ quote (Filename.concat root "ca.pem");
         "-CAkey " ^ quote (Filename.concat root "ca.key");
         "-CAcreateserial";
         "-out " ^ quote pem;
         "-days 30 -sha256";
         "-extfile " ^ quote cnf;
         "-extensions req_ext";
       ])

let prepare ~temp_dir =
  let cert_dir = Filename.concat temp_dir "certs" in
  mkdir_p cert_dir;
  let* () = create_ca cert_dir in
  let* () =
    create_leaf cert_dir ~name:"server" ~cn:"localhost"
      ~dns:[ "localhost"; "*.local.test" ]
      ~ips:[ "127.0.0.1" ]
  in
  Ok cert_dir

let ca_path cert_dir = Filename.concat cert_dir "ca.pem"
let cert_path cert_dir = Filename.concat cert_dir "server.pem"
let key_path cert_dir = Filename.concat cert_dir "server.key"
