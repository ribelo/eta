module Builder = H_s3_enforce_policy.Default_config_builder

let check name condition =
  if condition then Printf.printf "PASS %s\n%!" name
  else failwith ("FAIL " ^ name)

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let same_cipher_set left right =
  List.length left = List.length right && List.for_all (fun c -> List.mem c right) left

let pp_cipher cipher = Format.asprintf "%a" Tls.Ciphersuite.pp_ciphersuite cipher

let reject_if_dhe cipher =
  match Tls.Ciphersuite.ciphersuite_kex cipher with
  | `FFDHE -> false
  | _ -> true

let assert_config name client =
  let config = Tls.Config.of_client client in
  check (name ^ " version_range_tls12_only")
    (config.Tls.Config.protocol_versions = Builder.policy_version);
  check (name ^ " ciphers_exact_policy_set")
    (same_cipher_set config.ciphers Builder.policy_ciphers);
  check (name ^ " ciphers_no_dhe")
    (List.for_all reject_if_dhe config.ciphers);
  check (name ^ " no_tls13_ciphers")
    (Tls.Config.ciphers13 config = []);
  Printf.printf "CONFIG %s versions=tls12-tls12 ciphers=%s alpn=%s\n%!"
    name
    (String.concat ","
       (List.map pp_cipher config.ciphers))
    (String.concat "," config.alpn_protocols)

let () =
  let authenticator = authenticator () in
  let default_path = Builder.default_client ~authenticator () in
  let peer_path =
    Builder.default_client ~authenticator
      ~peer_name:(host_exn "api.openai.com") ()
  in
  let ip_path =
    Builder.default_client ~authenticator
      ~ip:(Ipaddr.of_string_exn "127.0.0.1") ()
  in
  let alpn_path =
    Builder.default_client ~authenticator
      ~alpn_protocols:[ "http/1.1" ] ()
  in
  assert_config "default_path" default_path;
  assert_config "peer_name_path" peer_path;
  assert_config "ip_literal_path" ip_path;
  assert_config "custom_alpn_path" alpn_path;
  Printf.printf "h_s3_enforce_invariants passed\n%!"
