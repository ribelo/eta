type replayability = Replayable | One_shot
type pull = unit -> bytes option

type upload_source =
  | Bytes of bytes
  | Stream of {
      length : int64 option;
      replayability : replayability;
      open_pull : unit -> pull;
      opened : bool Atomic.t;
    }

let bytes value = Bytes (Bytes.copy value)

let stream ?length ~replayability open_pull =
  Option.iter
    (fun length ->
      if Int64.compare length 0L < 0 then
        invalid_arg "Eta_ai.Audio.stream: length must not be negative")
    length;
  Stream { length; replayability; open_pull; opened = Atomic.make false }

let known_length = function
  | Bytes value -> Some (Int64.of_int (Bytes.length value))
  | Stream { length; _ } -> length

let replayability = function
  | Bytes _ -> Replayable
  | Stream { replayability; _ } -> replayability

let open_pull = function
  | Bytes value ->
      let available = ref true in
      fun () ->
        if !available then (
          available := false;
          Some (Bytes.copy value))
        else None
  | Stream { replayability; open_pull; opened; _ } ->
      (* One shot is claimed atomically, so concurrent domains cannot both
         obtain a reader. Replayable sources never write the flag. *)
      (match replayability with
      | Replayable -> ()
      | One_shot ->
          if not (Atomic.compare_and_set opened false true) then
            invalid_arg
              "Eta_ai.Audio.open_pull: a one-shot source cannot be reopened");
      open_pull ()

type upload = {
  filename : string;
  content_type : string;
  source : upload_source;
}

module Speech_to_text = struct
  type request = {
    upload : upload;
    language : string option;
  }

  type result = {
    text : string option;
    language : string option;
    duration_s : float option;
  }

  type neutral_request = request
  type neutral_result = result

  module type Provider = sig
    type request
    type result
    type error
    type configuration
    type request_construction

    val of_eta_ai : neutral_request -> request_construction

    val configure :
      configuration -> request_construction -> (request, error) Stdlib.result

    val to_eta_ai : result -> neutral_result
  end
end

module Text_to_speech = struct
  type encoding = Mp3 | Wav | Pcm

  type request = {
    text : string;
    voice : string;
    encoding : encoding option;
    speed : float option;
  }

  type result = {
    content_type : string option;
    audio : bytes;
  }

  type neutral_request = request
  type neutral_result = result

  module type Provider = sig
    type request
    type result
    type error
    type configuration
    type request_construction

    val of_eta_ai : neutral_request -> request_construction

    val configure :
      configuration -> request_construction -> (request, error) Stdlib.result

    val to_eta_ai : result -> neutral_result
  end
end
