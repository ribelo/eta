module A = Eta_ai
module X = Eta_ai_xai

let qcheck_seed = Random.State.make [| 0x0A1; 0x0A1 |]
let count = 100
let safe_string = QCheck.map string_of_int QCheck.int

let property_xai_conversion =
  let generated =
    QCheck.
      (pair
         (quad safe_string safe_string safe_string safe_string)
         (pair safe_string (pair bool int)))
  in
  QCheck.Test.make
    ~name:
      "oabridge-pmod/d348/ff14 generated xAI audio conversion requires configuration and projects explicitly"
    ~count generated
    (fun
      ( (text, voice, language_suffix, transcript),
        (audio, (diarize, duration_seed)) ) ->
          let neutral : A.Audio.Text_to_speech.request =
            {
              text = "text-" ^ text;
              voice = "voice-" ^ voice;
              encoding = Some A.Audio.Text_to_speech.Mp3;
              speed = Some 1.0;
            }
          in
          let construction = X.Audio.Text_to_speech.of_eta_ai neutral in
          let configure language =
            X.Audio.Text_to_speech.configure
              {
                language;
                sample_rate = Some 24000;
                bit_rate = Some 128000;
                optimize_streaming_latency = None;
                text_normalization = None;
                with_timestamps = false;
              }
              construction
          in
          let language_1 = "language-1-" ^ language_suffix in
          let language_2 = "language-2-" ^ language_suffix in
          let configured =
            match (configure language_1, configure language_2) with
            | Ok first, Ok second ->
                String.equal first.language language_1
                && String.equal second.language language_2
                && String.equal first.text neutral.text
                && first.voice_id = Some neutral.voice
            | Error _, _ | _, Error _ -> false
          in
          let encoding_conversion =
            List.for_all
              (fun (encoding, expected) ->
                let construction =
                  X.Audio.Text_to_speech.of_eta_ai
                    { neutral with encoding = Some encoding }
                in
                match
                  X.Audio.Text_to_speech.configure
                    {
                      language = language_1;
                      sample_rate = None;
                      bit_rate = None;
                      optimize_streaming_latency = None;
                      text_normalization = None;
                      with_timestamps = false;
                    }
                    construction
                with
                | Ok { output_format = Some { codec; _ }; _ } -> codec = expected
                | Ok _ | Error _ -> false)
              [
                (A.Audio.Text_to_speech.Mp3, X.Audio.Text_to_speech.Mp3);
                (Wav, X.Audio.Text_to_speech.Wav);
                (Pcm, X.Audio.Text_to_speech.Pcm);
              ]
          in
          let upload : A.Audio.upload =
            {
              filename = "sample.wav";
              content_type = "audio/wav";
              source = A.Audio.bytes (Bytes.of_string audio);
            }
          in
          let stt =
            X.Audio.Speech_to_text.of_eta_ai
              {
                A.Audio.Speech_to_text.upload = upload;
                language = Some language_1;
              }
          in
          let stt_configured =
            match
              X.Audio.Speech_to_text.configure
                {
                  audio_format = None;
                  sample_rate = None;
                  format = None;
                  multichannel = None;
                  channels = None;
                  diarize = Some diarize;
                  keyterm = [];
                  filler_words = None;
                  vad_threshold = None;
                }
                stt
            with
            | Ok request ->
                request.language = Some language_1
                && request.diarize = Some diarize
            | Error _ -> false
          in
          let projected_tts =
            X.Audio.Text_to_speech.to_eta_ai
              (X.Audio.Text_to_speech.Raw_audio
                 {
                   content_type = Some "audio/mpeg";
                   audio = Bytes.of_string audio;
                 })
          in
          let duration = float_of_int duration_seed /. 1000. in
          let projected_stt =
            X.Audio.Speech_to_text.to_eta_ai
              {
                text = transcript;
                language = Some language_1;
                duration = Some duration;
                words = [];
                channels = [];
                raw = "{}";
              }
          in
          configured && encoding_conversion && stt_configured
          && Bytes.equal projected_tts.audio (Bytes.of_string audio)
          && projected_stt.text = Some transcript
          && projected_stt.duration_s = Some duration)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [ property_xai_conversion ]
  in
  exit code
