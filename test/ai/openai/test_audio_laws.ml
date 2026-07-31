module A = Eta_ai
module O = Eta_ai_openai

let qcheck_seed = Random.State.make [| 0x0A1; 0xA0D10 |]
let count = 100
let safe_string = QCheck.Gen.map string_of_int QCheck.Gen.int

let property_openai_conversion =
  let generated =
    QCheck.Gen.
      (pair
         (quad safe_string safe_string safe_string safe_string)
         (pair safe_string (pair int int)))
  in
  QCheck.Test.make
    ~name:
      "oabridge-pmod/d348/ff14 generated OpenAI audio conversion requires configuration and projects explicitly"
    ~count
      (QCheck.make
         ~print:(fun
           ( (text, voice, model_suffix, language),
             (transcript, (speed_seed, duration_seed)) ) ->
           Printf.sprintf
             "{text=%S; voice=%S; model_suffix=%S; language=%S; transcript=%S; speed_seed=%d; duration_seed=%d}"
             text voice model_suffix language transcript speed_seed duration_seed)
         generated)
    (fun
      ( (text, voice, model_suffix, language),
        (transcript, (speed_seed, duration_seed)) ) ->
          let speed =
            0.25 +. (float_of_int (abs (speed_seed mod 376)) /. 100.)
          in
          let duration = float_of_int duration_seed /. 100. in
          let neutral : A.Audio.Text_to_speech.request =
            {
              text = "text-" ^ text;
              voice = "voice-" ^ voice;
              encoding = None;
              speed = Some speed;
            }
          in
          let construction = O.Audio.Text_to_speech.of_eta_ai neutral in
          let configure model =
            O.Audio.Text_to_speech.configure
              {
                model = O.Audio.Text_to_speech.Other model;
                instructions = None;
                extra = [];
              }
              construction
          in
          let model_1 = "model-1-" ^ model_suffix in
          let model_2 = "model-2-" ^ model_suffix in
          let configured =
            match (configure model_1, configure model_2) with
            | Ok first, Ok second ->
                String.equal
                     (O.Audio.Text_to_speech.model_to_string first.model)
                     model_1
                && String.equal
                     (O.Audio.Text_to_speech.model_to_string second.model)
                     model_2
                && String.equal first.input neutral.text
                && first.voice =
                   O.Audio.Voices.Built_in
                     (O.Audio.Voices.Other neutral.voice)
                && first.speed = neutral.speed
            | Error _, _ | _, Error _ -> false
          in
          let encodings =
            [
              (A.Audio.Text_to_speech.Mp3, "mp3");
              (Wav, "wav");
              (Pcm, "pcm");
            ]
          in
          let encoding_conversion =
            List.for_all
              (fun (encoding, expected) ->
                let construction =
                  O.Audio.Text_to_speech.of_eta_ai
                    { neutral with encoding = Some encoding }
                in
                match
                  O.Audio.Text_to_speech.configure
                    {
                      model = O.Audio.Text_to_speech.Other model_1;
                      instructions = None;
                      extra = [];
                    }
                    construction
                with
                | Ok request ->
                    let actual =
                      match request.response_format with
                      | Some O.Audio.Text_to_speech.Mp3 -> "mp3"
                      | Some Opus -> "opus"
                      | Some Aac -> "aac"
                      | Some Flac -> "flac"
                      | Some Wav -> "wav"
                      | Some Pcm -> "pcm"
                      | None -> ""
                    in
                    String.equal actual expected
                | Error _ -> false)
              encodings
          in
          let upload : A.Audio.upload =
            {
              filename = "sample.wav";
              content_type = "audio/wav";
              source = A.Audio.bytes (Bytes.of_string text);
            }
          in
          let stt =
            O.Audio.Speech_to_text.of_eta_ai
              {
                A.Audio.Speech_to_text.upload = upload;
                language = Some language;
              }
          in
          let stt_configured =
            match
              O.Audio.Speech_to_text.configure
                {
                  model = model_1;
                  prompt = None;
                  response_format = None;
                  temperature = None;
                  extra_fields = [];
                }
                stt
            with
            | Ok request ->
                String.equal request.model model_1
                && request.language = Some language
            | Error _ -> false
          in
          let projected_tts =
            O.Audio.Text_to_speech.to_eta_ai
              {
                content_type = Some "audio/wav";
                audio = Bytes.of_string text;
              }
          in
          let projected_stt =
            O.Audio.Speech_to_text.to_eta_ai
              {
                text = Some transcript;
                language = Some language;
                duration_s = Some duration;
                usage = None;
                raw = Some "{}";
              }
          in
          configured && encoding_conversion && stt_configured
          && Bytes.equal projected_tts.audio (Bytes.of_string text)
          && projected_stt.text = Some transcript
          && projected_stt.language = Some language
          && projected_stt.duration_s = Some duration)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [ property_openai_conversion ]
  in
  exit code
