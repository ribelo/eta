let h2_chr n = Char.chr (n land 0xff)

let h2_frame_header ~length ~frame_type ~flags ~stream_id =
  String.init 9 @@ function
  | 0 -> h2_chr ((length lsr 16) land 0xff)
  | 1 -> h2_chr ((length lsr 8) land 0xff)
  | 2 -> h2_chr (length land 0xff)
  | 3 -> h2_chr frame_type
  | 4 -> h2_chr flags
  | 5 -> h2_chr ((stream_id lsr 24) land 0x7f)
  | 6 -> h2_chr ((stream_id lsr 16) land 0xff)
  | 7 -> h2_chr ((stream_id lsr 8) land 0xff)
  | 8 -> h2_chr (stream_id land 0xff)
  | _ -> assert false

let h2_uint32 n =
  String.init 4 @@ function
  | 0 -> h2_chr ((n lsr 24) land 0xff)
  | 1 -> h2_chr ((n lsr 16) land 0xff)
  | 2 -> h2_chr ((n lsr 8) land 0xff)
  | 3 -> h2_chr (n land 0xff)
  | _ -> assert false

let settings_frame =
  h2_frame_header ~length:0 ~frame_type:0x4 ~flags:0 ~stream_id:0

let headers_frame =
  h2_frame_header ~length:0 ~frame_type:0x1 ~flags:0x4 ~stream_id:1

let goaway_frame =
  h2_frame_header ~length:8 ~frame_type:0x7 ~flags:0 ~stream_id:0
  ^ h2_uint32 1
  ^ h2_uint32 0

let payload len = String.make len '\000'

type attack = {
  id : string;
  data : string;
  expect : Http.Error.kind -> bool;
}

let attacks =
  [
    {
      id = "settings_churn";
      data = String.concat "" (List.init 11 (fun _ -> settings_frame));
      expect =
        (function Http.Error.Settings_churn_rate_exceeded _ -> true | _ -> false);
    };
    {
      id = "header_churn";
      data = String.concat "" (List.init 33 (fun _ -> headers_frame));
      expect =
        (function
        | Http.Error.Response_header_change_rate_exceeded _ -> true
        | _ -> false);
    };
    {
      id = "goaway_churn";
      data = goaway_frame ^ goaway_frame;
      expect = (function Http.Error.Connection_closed _ -> true | _ -> false);
    };
    {
      id = "hpack_block_cap";
      data =
        h2_frame_header ~length:(300 * 1024) ~frame_type:0x1 ~flags:0x4
          ~stream_id:1;
      expect =
        (function Http.Error.Hpack_decode_overflow _ -> true | _ -> false);
    };
    {
      id = "continuation_cap";
      data =
        h2_frame_header ~length:(40 * 1024) ~frame_type:0x1 ~flags:0
          ~stream_id:1
        ^ payload (40 * 1024)
        ^ h2_frame_header ~length:(30 * 1024) ~frame_type:0x9 ~flags:0x4
            ~stream_id:1;
      expect =
        (function Http.Error.Continuation_flood _ -> true | _ -> false);
    };
  ]

let run_attack attack =
  let client = H2.Client_connection.create ~error_handler:(fun _ -> ()) () in
  let reader =
    Http.H2.Multiplexer.create_client_reader ~buffer_size:(128 * 1024)
      client
  in
  let source = Eio.Flow.cstruct_source [ Cstruct.of_string attack.data ] in
  Gc.compact ();
  let before = (Gc.stat ()).Gc.minor_words in
  let rec loop remaining =
    if remaining = 0 then failwith (attack.id ^ ": no security error")
    else
      match Http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Security_error kind -> kind
      | Read _ | Eof _ -> loop (remaining - 1)
      | Close -> failwith (attack.id ^ ": closed before security error")
  in
  let kind = loop 32 in
  let after = (Gc.stat ()).Gc.minor_words in
  let minor_words = after -. before in
  if not (attack.expect kind) then
    failwith
      (Printf.sprintf "%s: unexpected %s" attack.id
         (Http.Error.kind_name kind));
  Printf.printf
    "eta_http_s4_envelope_alloc attack=%s outcome=ok error=%s minor_words=%.0f \
     limit_words=2260\n%!"
    attack.id (Http.Error.kind_name kind) minor_words;
  minor_words

let run_header_validation () =
  Gc.compact ();
  let before = (Gc.stat ()).Gc.minor_words in
  let kind =
    Http.H2.Security.validate_headers [ String.make 8193 'x', "value" ]
  in
  let after = (Gc.stat ()).Gc.minor_words in
  match kind with
  | Some (Http.Error.Header_invalid _) ->
      let minor_words = after -. before in
      Printf.printf
        "eta_http_s4_envelope_alloc attack=header_normalization outcome=ok \
         error=Header_invalid minor_words=%.0f limit_words=2260\n%!"
        minor_words;
      minor_words
  | Some kind ->
      failwith
        (Printf.sprintf "header_normalization: unexpected %s"
           (Http.Error.kind_name kind))
  | None -> failwith "header_normalization: no security error"

let () =
  let samples = List.map run_attack attacks @ [ run_header_validation () ] in
  let max_sample = List.fold_left max 0.0 samples in
  let verdict = if max_sample <= 2260.0 then "PASS" else "FAIL" in
  Printf.printf
    "eta_http_s4_envelope_alloc_summary verdict=%s attacks=%d \
     max_minor_words=%.0f limit_words=2260\n%!"
    verdict (List.length samples) max_sample;
  if not (String.equal verdict "PASS") then exit 1
