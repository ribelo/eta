module A = Eta_ai
module E = Eta.Effect
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type source =
  | File of A.Audio.upload
  | Url of string

type raw_audio_format = Pcm | Mulaw | Alaw

type request = {
  source : source;
  audio_format : raw_audio_format option;
  sample_rate : int option;
  language : string option;
  format : bool option;
  multichannel : bool option;
  channels : int option;
  diarize : bool option;
  keyterm : string list;
  filler_words : bool option;
  vad_threshold : float option;
}

type word = {
  text : string;
  start : float option;
  end_ : float option;
  confidence : float option;
  speaker : int option;
  raw : A.Json.t;
}

type channel = {
  index : int option;
  text : string option;
  words : word list;
  raw : A.Json.t;
}

type response = {
  text : string;
  language : string option;
  duration : float option;
  words : word list;
  channels : channel list;
  raw : A.raw_json;
}

type configuration = {
  audio_format : raw_audio_format option;
  sample_rate : int option;
  format : bool option;
  multichannel : bool option;
  channels : int option;
  diarize : bool option;
  keyterm : string list;
  filler_words : bool option;
  vad_threshold : float option;
}

type request_construction = A.Audio.Speech_to_text.request

let of_eta_ai request = request

let to_eta_ai (response : response) : A.Audio.Speech_to_text.result =
  {
    text = Some response.text;
    language = response.language;
    duration_s = response.duration;
  }

let sample_rates = [ 8000; 16000; 22050; 24000; 44100; 48000 ]

let bool_string = function true -> "true" | false -> "false"

let option_field name f = function
  | None -> []
  | Some value ->
      [ Eta_http.Multipart.Text { name; value = f value } ]

let validate request =
  let* () =
    match request.source with
    | File file -> (
        match A.Audio.known_length file.source with
        | Some length when Int64.compare length 500_000_000L > 0 ->
            C.invalid "speech-to-text file exceeds 500 MB"
        | Some _ | None -> Ok ())
    | _ -> Ok ()
  in
  let* () =
    match (request.audio_format, request.sample_rate) with
    | Some _, Some rate when List.mem rate sample_rates -> Ok ()
    | Some _, Some _ ->
        C.invalid
          "raw speech-to-text sample_rate must be 8000, 16000, 22050, 24000, 44100, or 48000"
    | Some _, None ->
        C.invalid "raw speech-to-text audio requires sample_rate"
    | None, Some _ ->
        C.invalid "sample_rate requires raw speech-to-text audio_format"
    | None, None -> Ok ()
  in
  let* () =
    match request.channels with
    | Some value when value < 2 || value > 8 ->
        C.invalid "speech-to-text channels must be between 2 and 8"
    | _ -> Ok ()
  in
  let* () =
    match (request.format, request.language) with
    | Some true, None ->
        C.invalid "speech-to-text format=true requires language"
    | _ -> Ok ()
  in
  let* () =
    if List.length request.keyterm > 100 then
      C.invalid "speech-to-text accepts at most 100 keyterms"
    else
      C.result_map_all
        (fun term ->
          let* count = C.utf8_scalar_count "speech-to-text keyterm" term in
          if count > 50 then
            C.invalid "speech-to-text keyterms must not exceed 50 characters"
          else Ok ())
        request.keyterm
      |> Result.map (fun _ -> ())
  in
  match request.vad_threshold with
  | None -> Ok ()
  | Some value ->
      let* _ = C.finite_float "vad_threshold" value in
      Ok ()

let configure configuration (construction : request_construction) =
  let request =
    {
      source = File construction.upload;
      audio_format = configuration.audio_format;
      sample_rate = configuration.sample_rate;
      language = construction.language;
      format = configuration.format;
      multichannel = configuration.multichannel;
      channels = configuration.channels;
      diarize = configuration.diarize;
      keyterm = configuration.keyterm;
      filler_words = configuration.filler_words;
      vad_threshold = configuration.vad_threshold;
    }
  in
  Result.map (fun () -> request) (validate request)

let read_upload (upload : A.Audio.upload) =
  let buffer = Buffer.create 4096 in
  let pull = A.Audio.open_pull upload.source in
  let rec loop total =
    match pull () with
    | None -> Ok (Bytes.of_string (Buffer.contents buffer))
    | Some chunk ->
        let total = total + Bytes.length chunk in
        if total > 500_000_000 then C.invalid "speech-to-text file exceeds 500 MB"
        else (
          Buffer.add_bytes buffer chunk;
          loop total)
    | exception exn ->
        C.invalid
          ("speech-to-text upload source failed: " ^ Printexc.to_string exn)
  in
  loop 0

let request ?(endpoint = Endpoint.default_inference) ~api_key request =
  let* () = validate request in
  let audio_format =
    Option.map
      (function Pcm -> "pcm" | Mulaw -> "mulaw" | Alaw -> "alaw")
      request.audio_format
  in
  let fields =
    option_field "audio_format" Fun.id audio_format
    @ option_field "sample_rate" string_of_int request.sample_rate
    @ option_field "language" Fun.id request.language
    @ option_field "format" bool_string request.format
    @ option_field "multichannel" bool_string request.multichannel
    @ option_field "channels" string_of_int request.channels
    @ option_field "diarize" bool_string request.diarize
    @ List.map
        (fun value -> Eta_http.Multipart.Text { name = "keyterm"; value })
        request.keyterm
    @ option_field "filler_words" bool_string request.filler_words
    @ option_field "vad_threshold" (Printf.sprintf "%.17g") request.vad_threshold
  in
  let* parts =
    match request.source with
    | Url url ->
        Ok (fields @ [ Eta_http.Multipart.Text { name = "url"; value = url } ])
    | File file ->
        let* data = read_upload file in
        Ok
          (fields
          @ [
              Eta_http.Multipart.File
                {
                  name = "file";
                  filename = file.filename;
                  content_type = file.content_type;
                  data = Eta_http.Multipart.Buffered data;
                };
            ])
  in
  let* multipart =
    Eta_http.Multipart.make parts
    |> Result.map_error (C.multipart_error ~label:"speech-to-text")
  in
  let base_url = Endpoint.inference_base_url endpoint in
  let headers =
    C.inference_headers api_key
    |> Eta_http.Core.Header.remove "content-type"
    |> Eta_http.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ multipart.boundary)
  in
  Ok
    (Eta_http.Request.make ~headers ~body:multipart.body "POST"
       (C.join_url base_url "/v1/stt"))

let word json =
  match Json.string_member "text" json with
  | None -> None
  | Some text ->
      Some
        {
          text;
          start = C.float_member "start" json;
          end_ = C.float_member "end" json;
          confidence = C.float_member "confidence" json;
          speaker = Json.int_member "speaker" json;
          raw = json;
        }

let words json =
  Json.array_member "words" json |> Option.value ~default:[]
  |> List.filter_map word

let channel json =
  {
    index = Json.int_member "index" json;
    text = Json.string_member "text" json;
    words = words json;
    raw = json;
  }

let decode_response raw =
  let* json = C.parse_json raw in
  let* text = C.required_string "text" json in
  Ok
    {
      text;
      language = Json.string_member "language" json;
      duration = C.float_member "duration" json;
      words = words json;
      channels =
        Json.array_member "channels" json |> Option.value ~default:[]
        |> List.map channel;
      raw;
    }

let transcribe ?(endpoint = Endpoint.default_inference) client ~api_key
    (request_value : request) =
  let base_url = Endpoint.inference_base_url endpoint in
  let attrs =
    match request_value.audio_format with
    | None -> []
    | Some format ->
        [
          ( "gen_ai.request.encoding_formats",
            match format with Pcm -> "pcm" | Mulaw -> "mulaw" | Alaw -> "alaw" );
        ]
  in
  match request ~endpoint ~api_key request_value with
  | Error error -> E.fail error
  | Ok http_request ->
      C.perform_json ~base_url ~operation:"transcription" ~attrs client
        http_request decode_response
