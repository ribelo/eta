open Test_eta_http_support

let test_url_rejects_invalid_reg_name_hosts () =
  let cases =
    [
      "http://exa[mple.test/";
      "http://exa]mple.test/";
      "http://example%.test/";
      "http://example%zz.test/";
    ]
  in
  List.iter
    (fun raw ->
      match Eta_http.Core.Url.parse raw with
      | Error _ -> ()
      | Ok url ->
            Alcotest.failf "invalid host accepted: %S as authority %S" raw
              (Eta_http.Core.Url.authority url))
    cases

let test_url_rejects_invalid_path_query_percent_encoding () =
  let cases =
    [
      "http://example.test/%";
      "http://example.test/%zz";
      "http://example.test/path?x=%";
      "http://example.test/path?x=%q0";
      "http://example.test/bad[char]";
    ]
  in
  List.iter
    (fun raw ->
      match Eta_http.Core.Url.parse raw with
      | Error _ -> ()
      | Ok url ->
          Alcotest.failf "invalid URL accepted: %S as origin-form %S" raw
            (Eta_http.Core.Url.origin_form url))
    cases

let test_url_rejects_invalid_ip_literals () =
  let cases =
    [
      "http://[abc]/";
      "http://[::ffff:999.1.1.1]/";
      "http://[v.x]/";
      "http://[v1.]/";
    ]
  in
  List.iter
    (fun raw ->
      match Eta_http.Core.Url.parse raw with
      | Error _ -> ()
      | Ok url ->
            Alcotest.failf "invalid IP literal accepted: %S as authority %S" raw
              (Eta_http.Core.Url.authority url))
    cases

let test_url_accepts_valid_ip_literals () =
  let cases =
    [ ("http://[::1]/", "[::1]"); ("http://[v1.fe80]/", "[v1.fe80]") ]
  in
  List.iter
    (fun (raw, expected_authority) ->
      match Eta_http.Core.Url.parse raw with
      | Error error ->
          Alcotest.failf "valid IP literal rejected: %S: %a" raw
            Eta_http.Core.Url.pp_parse_error error
      | Ok url ->
          Alcotest.(check string)
            "authority" expected_authority
            (Eta_http.Core.Url.authority url))
    cases
