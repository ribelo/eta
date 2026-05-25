open Test_eta_http_support

let test_url_parse_client_subset () =
  let url =
    Http.Core.Url.of_string
      "https://API.Example.test:8443/v1/models?limit=1#top"
  in
  Alcotest.(check string) "scheme" "https"
    (Http.Core.Url.scheme_to_string (Http.Core.Url.scheme url));
  Alcotest.(check string) "host lowercased" "api.example.test"
    (Http.Core.Url.host url);
  Alcotest.(check (option int)) "port" (Some 8443)
    (Http.Core.Url.port url);
  Alcotest.(check int) "effective port" 8443
    (Http.Core.Url.effective_port url);
  Alcotest.(check string) "path" "/v1/models" (Http.Core.Url.path url);
  Alcotest.(check (option string)) "query" (Some "limit=1")
    (Http.Core.Url.query url);
  Alcotest.(check (option string)) "fragment" (Some "top")
    (Http.Core.Url.fragment url);
  Alcotest.(check string) "origin form" "/v1/models?limit=1"
    (Http.Core.Url.origin_form url);
  Alcotest.(check string) "authority" "api.example.test:8443"
    (Http.Core.Url.authority url)

let test_url_ipv6_authority_restores_brackets () =
  let url = Http.Core.Url.of_string "https://[::1]:8443/path" in
  Alcotest.(check string) "host unbracketed" "::1" (Http.Core.Url.host url);
  Alcotest.(check string) "authority bracketed" "[::1]:8443"
    (Http.Core.Url.authority url);
  let bytes = Bytes.create 64 in
  let len = Http.Core.Url.blit_authority bytes ~pos:0 url in
  Alcotest.(check string) "raw authority" "[::1]:8443"
    (Bytes.sub_string bytes 0 len);
  (match
     Http.H1.Write.to_string ~method_:"GET" ~url ~headers:[]
       ~body:Http.H1.Write.Empty
   with
  | Error error -> Alcotest.fail (Http.Error.to_string error)
  | Ok wire ->
      Alcotest.(check bool) "host header" true
        (contains wire "\r\nHost: [::1]:8443\r\n"));
  let no_port = Http.Core.Url.of_string "https://[2001:db8::1]/" in
  Alcotest.(check string) "authority no port" "[2001:db8::1]"
    (Http.Core.Url.authority no_port);
  let reg_name = Http.Core.Url.of_string "https://example.com:8080/" in
  Alcotest.(check string) "reg-name authority" "example.com:8080"
    (Http.Core.Url.authority reg_name)

let test_url_rejects_unsupported_forms () =
  let check_error label expected raw =
    match Http.Core.Url.parse raw with
    | Ok _ -> Alcotest.failf "%s unexpectedly parsed" label
    | Error actual ->
        Alcotest.(check string)
          label expected
          (Http.Core.Url.parse_error_to_string actual)
  in
  check_error "userinfo" "userinfo is not supported"
    "https://user:pass@example.test/";
  check_error "scheme" "unsupported URL scheme \"ftp\""
    "ftp://example.test/";
  check_error "port" "invalid URL port \"99999\""
    "https://example.test:99999/"


