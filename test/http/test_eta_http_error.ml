open Test_eta_http_support

let expect_absent label needle haystack =
  Alcotest.(check bool) label false (contains haystack needle)

let expect_present label needle haystack =
  Alcotest.(check bool) label true (contains haystack needle)

let test_error_redacts_proxy_authentication_headers () =
  let error =
    Eta_http.Error.make ~method_:"GET" ~uri:"http://example.test/"
      (HTTP_status
         {
           status = 407;
           headers =
             [
               ("Proxy-Authorization", "Basic proxy-credential-secret");
               ("WWW-Authenticate", "Basic www-challenge-secret");
               ("Proxy-Authenticate", "Basic proxy-challenge-secret");
             ];
         })
  in
  let rendered = Eta_http.Error.to_string error in
  let json = Eta_http.Error_projection.to_json error in
  List.iter
    (fun secret ->
      expect_absent ("rendered redacts " ^ secret) secret rendered;
      expect_absent ("json redacts " ^ secret) secret json)
    [
      "proxy-credential-secret";
      "www-challenge-secret";
      "proxy-challenge-secret";
    ];
  expect_present "rendered has redaction marker" "<redacted>" rendered;
  expect_present "json has redaction marker" "<redacted>" json

let test_redaction_uri_redacts_userinfo () =
  let redacted =
    Eta_http.Error.Redaction.uri
      "http://alice:super-secret@example.test/path?q=1#frag"
  in
  Alcotest.(check string)
    "redacts userinfo, query, and fragment"
    "http://<redacted>@example.test/path?<redacted>#<redacted>"
    redacted

let test_redaction_uri_redacts_query () =
  let redacted =
    Eta_http.Error.Redaction.uri
      "https://api.example.test/private?token=secret&email=a@example.test#frag"
  in
  Alcotest.(check string)
    "redacts query and fragment"
    "https://api.example.test/private?<redacted>#<redacted>" redacted;
  expect_absent "query secret absent" "token=secret" redacted;
  expect_absent "email secret absent" "a@example.test" redacted

let test_redaction_uri_redacts_fragments () =
  let cases =
    [
      "http://example.test/cb#access_token=super-secret";
      "http://example.test/cb?code=abc#id_token=super-secret";
    ]
  in
  List.iter
    (fun uri ->
      let redacted = Eta_http.Error.Redaction.uri uri in
      expect_absent "fragment secret absent" "super-secret" redacted;
      expect_present "fragment marker redacted" "#<redacted>" redacted)
    cases;

  let error =
    Eta_http.Error.make ~method_:"GET"
      ~uri:"http://example.test/cb#access_token=super-secret"
      (Connection_closed { during = Http_response })
  in
  expect_absent "error string redacts fragment secret" "super-secret"
    (Eta_http.Error.to_string error)

let test_semconv_uses_error_redaction_for_uri_and_location () =
  let request =
    Eta_http.Request.make "GET"
      "http://alice:super-secret@example.test/path?token=secret#frag"
  in
  let attrs =
    Eta_http.Observability.Semconv.request_attrs ~protocol:Eta_http.Client.H1
      request
  in
  Alcotest.(check (option string))
    "semconv url.full uses Error.Redaction"
    (Some "http://<redacted>@example.test/path?<redacted>#<redacted>")
    (List.assoc_opt "url.full" attrs);
  let location =
    "https://api.example.test/next?token=secret#access_token=super-secret"
  in
  let redirect =
    Eta_http.Observability.Semconv.redirect_attrs ~location ()
  in
  Alcotest.(check (option string))
    "semconv location uses Error.Redaction"
    (Some "https://api.example.test/next?<redacted>#<redacted>")
    (List.assoc_opt "http.response.header.location" redirect);
  expect_absent "location secret absent" "super-secret"
    (Option.value ~default:""
       (List.assoc_opt "http.response.header.location" redirect))

let test_error_redacts_uri_userinfo_in_outputs () =
  let error =
    Eta_http.Error.make ~method_:"GET"
      ~uri:"http://alice:super-secret@example.test/path?q=1#frag"
      (Connect_error { message = "failed" })
  in
  let rendered = Eta_http.Error.to_string error in
  let json = Eta_http.Error_projection.to_json error in
  expect_absent "rendered redacts username" "alice" rendered;
  expect_absent "rendered redacts password" "super-secret" rendered;
  expect_absent "json redacts username" "alice" json;
  expect_absent "json redacts password" "super-secret" json;
  expect_present "rendered has redaction marker" "<redacted>" rendered;
  expect_present "json has redaction marker" "<redacted>" json
