open Eta_http_fuzz_support

let parse_case =
  Crowbar.dynamic_bind (bounded_bytes 192) (fun bytes ->
      Crowbar.map [ Crowbar.range (Bytes.length bytes + 1) ] (fun len ->
          (bytes, len)))

let check_response_spans bytes len (response : Eta_http_h1.Parse.response) =
  check_span "reason" len response.reason;
  check_span "body" len response.body;
  List.iter
    (fun (header : Eta_http_h1.Parse.header) ->
      check_span "header name" len header.name;
      check_span "header value" len header.value;
      ignore (Eta_http_h1.Parse.header_name bytes header : string);
      ignore (Eta_http_h1.Parse.header_value bytes header : string))
    response.headers;
  ignore (Eta_http_h1.Parse.span_to_string bytes response.reason : string);
  ignore (Eta_http_h1.Parse.body_to_bytes bytes response : bytes);
  ignore
    (Eta_http_h1.Parse.headers_to_list bytes response.headers
      : (string * string) list)

let () =
  Crowbar.add_test ~name:"h1 parser arbitrary bytes stay in bounds"
    [ parse_case ] (fun (bytes, len) ->
      match Eta_http_h1.Parse.parse bytes ~len with
      | Error _ -> ()
      | Ok response -> check_response_spans bytes len response)
