(** Curl shell-out and result normalization for differential testing. *)

open Types

let build_curl_cmd ~url ~method_ ~headers ~body_path ~insecure ~http2 ~tmp_dir =
  let body_out = Filename.concat tmp_dir "curl_body_out" in
  let headers_out = Filename.concat tmp_dir "curl_headers" in
  let parts =
    ref [
      "curl";
      "-s";
      "--connect-timeout";
      "3";
      "--max-time";
      "10";
      "-w";
      "\\n%{http_code}";
      "-o";
      body_out;
      "-D";
      headers_out;
    ]
  in
  if insecure then parts := !parts @ [ "-k" ];
  if http2 then parts := !parts @ [ "--http2" ];
  if String.equal method_ "HEAD" then parts := !parts @ [ "-I" ]
  else parts := !parts @ [ "-X"; method_ ];
  List.iter (fun (k, v) -> parts := !parts @ [ "-H"; Printf.sprintf "%s: %s" k v ]) headers;
  (match body_path with
   | Some path -> parts := !parts @ [ "-d"; "@" ^ path ]
   | None -> ());
  parts := !parts @ [ url ];
  String.concat " " (List.map Filename.quote !parts)

let normalize_headers raw_lines =
  let headers = ref [] in
  let rec parse = function
    | [] -> ()
    | line :: rest ->
        (match String.split_on_char ':' line with
         | name :: values ->
             let name = String.trim (String.lowercase_ascii name) in
             let value = String.trim (String.concat ":" values) in
	             if name <> "" && name <> "date" && name <> "server" && name <> "via" && name <> "set-cookie"
                && name <> "connection" && name <> "transfer-encoding" then
               headers := (name, value) :: !headers
         | _ -> ());
        parse rest
  in
  parse raw_lines;
  List.sort (fun (a, _) (b, _) -> String.compare a b) !headers
  |> List.map (fun (k, v) -> (k, v))

let read_header_lines tmp_dir =
  let path = Filename.concat tmp_dir "curl_headers" in
  if Sys.file_exists path then
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop acc =
           match input_line ic with
           | line -> loop (line :: acc)
           | exception End_of_file -> List.rev acc
         in
         loop [])
  else []

let run ~url ~method_ ~headers ~body_path ~insecure ~http2 ~tmp_dir =
  let cmd = build_curl_cmd ~url ~method_ ~headers ~body_path ~insecure ~http2 ~tmp_dir in
  match Util.run_cmd_out cmd with
  | Ok lines ->
      let status =
        match List.rev lines with
        | last :: _ -> (try int_of_string (String.trim last) with _ -> 0)
        | [] -> 0
      in
      let body_out = Filename.concat tmp_dir "curl_body_out" in
	      let body_sha256, body_length =
	        if String.equal method_ "HEAD" then (Util.sha256_of_string "", 0)
	        else if Sys.file_exists body_out then
	          (Util.sha256_of_file body_out, (Unix.stat body_out).st_size)
	        else ("", 0)
	      in
      let header_lines =
        read_header_lines tmp_dir
        |> List.filter (fun line -> String.length line > 0 && not (String.starts_with ~prefix:"HTTP/" line))
      in
      let headers_normalized = normalize_headers header_lines in
      Ok { status; body_sha256; body_length; headers_normalized }
  | Error msg -> Error msg

let result_equal (a : normalized_result) (b : normalized_result) =
  a.status = b.status
  && a.body_sha256 = b.body_sha256
  && a.body_length = b.body_length
  && a.headers_normalized = b.headers_normalized
