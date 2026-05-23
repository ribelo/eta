type outcome =
  | Handshake_ok of {
      alpn : string option;
      version : string;
    }
  | Handshake_error of string

type expected =
  | Accept_valid_tls
  | Reject_expired
  | Reject_invalid_chain
  | Reject_name_mismatch
  | Reject_weak_dh
  | Reject_weak_cipher

type case = {
  name : string;
  host : string;
  expected : expected;
}

let narrowed_ciphers =
  [
    `ECDHE_RSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_RSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256;
    `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;
    `ECDHE_ECDSA_WITH_AES_256_GCM_SHA384;
    `ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256;
  ]

let policy_version = (`TLS_1_2, `TLS_1_2)

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let ca_authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let classify_error exn = Printexc.to_string exn

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let string_of_expected = function
  | Accept_valid_tls -> "accept_valid_tls"
  | Reject_expired -> "reject_expired"
  | Reject_invalid_chain -> "reject_invalid_chain"
  | Reject_name_mismatch -> "reject_name_mismatch"
  | Reject_weak_dh -> "reject_weak_dh"
  | Reject_weak_cipher -> "reject_weak_cipher"

let observed_error_class error =
  if contains ~needle:"has expired" error || contains ~needle:"expired" error
  then "reject_expired"
  else if contains ~needle:"invalid certificate chain" error
  then "reject_invalid_chain"
  else if contains ~needle:"does not contain the name" error
  then "reject_name_mismatch"
  else if contains ~needle:"handshake failure" error
  then "reject_handshake_failure"
  else if contains ~needle:"no configured ciphersuite" error
  then "reject_no_cipher"
  else if contains ~needle:"timeout" error
  then "reject_timeout"
  else "reject_other"

let truncate max_len value =
  if String.length value <= max_len then value
  else String.sub value 0 max_len ^ "..."

let error_detail error =
  match observed_error_class error with
  | "reject_other" -> truncate 160 error
  | class_ -> class_

let accepted_class = function
  | Reject_weak_dh -> "accepted_weak_dh"
  | Reject_weak_cipher -> "accepted_weak_cipher"
  | Accept_valid_tls | Reject_expired | Reject_invalid_chain
  | Reject_name_mismatch ->
      "accepted"

let outcome_matches expected = function
  | Handshake_ok _ -> (
      match expected with
      | Accept_valid_tls -> true
      | Reject_expired | Reject_invalid_chain | Reject_name_mismatch
      | Reject_weak_dh | Reject_weak_cipher ->
          false)
  | Handshake_error error -> (
      match expected with
      | Accept_valid_tls -> false
      | Reject_expired -> observed_error_class error = "reject_expired"
      | Reject_invalid_chain ->
          observed_error_class error = "reject_invalid_chain"
      | Reject_name_mismatch ->
          observed_error_class error = "reject_name_mismatch"
      | Reject_weak_dh | Reject_weak_cipher -> true)

let connect_host env host =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock 10.0 (fun () ->
        Ok
          (Eio.Switch.run @@ fun sw ->
           let addr =
             match Eio.Net.getaddrinfo_stream net host ~service:"443" with
             | [] -> failwith ("no addresses for " ^ host)
             | addr :: _ -> addr
           in
           let raw_flow = Eio.Net.connect ~sw net addr in
           let tls_flow =
             Tls_eio.client_of_flow
               (Tls.Config.client
                  ~authenticator:(ca_authenticator ())
                  ~alpn_protocols:[ "http/1.1" ]
                  ~version:policy_version
                  ~ciphers:narrowed_ciphers
                  ())
               ~host:(host_exn host)
               raw_flow
           in
           let epoch =
             match Tls_eio.epoch tls_flow with
             | Ok epoch -> epoch
             | Error () -> failwith "TLS epoch unavailable"
           in
           let outcome =
             Handshake_ok
               {
                 alpn = epoch.Tls.Core.alpn_protocol;
                 version = string_of_tls_version epoch.Tls.Core.protocol_version;
               }
           in
           Eio.Resource.close tls_flow;
           outcome))
  with
  | Ok outcome -> outcome
  | Error `Timeout -> Handshake_error "timeout"
  | exception exn -> Handshake_error (classify_error exn)

let cases =
  [
    { name = "expired"; host = "expired.badssl.com"; expected = Reject_expired };
    {
      name = "self_signed";
      host = "self-signed.badssl.com";
      expected = Reject_invalid_chain;
    };
    {
      name = "untrusted_root";
      host = "untrusted-root.badssl.com";
      expected = Reject_invalid_chain;
    };
    {
      name = "wrong_host";
      host = "wrong.host.badssl.com";
      expected = Reject_name_mismatch;
    };
    { name = "dh1024"; host = "dh1024.badssl.com"; expected = Reject_weak_dh };
    {
      name = "rc4_md5";
      host = "rc4-md5.badssl.com";
      expected = Reject_weak_cipher;
    };
    { name = "hsts"; host = "hsts.badssl.com"; expected = Accept_valid_tls };
  ]

let () =
  Eio_main.run @@ fun env ->
  let failures =
    List.filter_map
      (fun case ->
        let outcome = connect_host env case.host in
        let result =
          if outcome_matches case.expected outcome then "PASS" else "FAIL"
        in
        (match outcome with
        | Handshake_ok { alpn; version } ->
            Printf.printf
              "h_s3_pivot_badssl name=%s host=%s expected=%s observed=%s result=%s version=%s alpn=%s policy=tls12_ecdhe_aead_only\n\
               %!"
              case.name case.host
              (string_of_expected case.expected)
              (accepted_class case.expected)
              result version
              (Option.value ~default:"<none>" alpn)
        | Handshake_error error ->
            Printf.printf
              "h_s3_pivot_badssl name=%s host=%s expected=%s observed=%s result=%s detail=%S policy=tls12_ecdhe_aead_only\n\
               %!"
              case.name case.host
              (string_of_expected case.expected)
              (observed_error_class error)
              result
              (error_detail error));
        if result = "PASS" then None else Some case.name)
      cases
  in
  match failures with
  | [] ->
      Printf.printf
        "h_s3_pivot_badssl_summary verdict=PASS failed=<none> policy=tls12_ecdhe_aead_only\n\
         %!"
  | failures ->
      Printf.printf
        "h_s3_pivot_badssl_summary verdict=FAIL failed=%s policy=tls12_ecdhe_aead_only\n\
         %!"
        (String.concat "," failures)
