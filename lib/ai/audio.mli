(** Provider-neutral audio vocabulary.

    This module contains only the request and result fields shared by OpenAI and
    xAI. Providers retain their complete request and result types and expose
    explicit conversion at this boundary. *)

type replayability = Replayable | One_shot

type pull = unit -> bytes option
(** A pull reader returns the next byte chunk, or [None] at end of input. *)

type upload_source

val bytes : bytes -> upload_source
(** An in-memory, replayable source whose length is always known. The bytes are
    copied, so later mutation of the argument cannot change what a reader
    yields, and each reader receives its own copy. *)

val stream :
  ?length:int64 ->
  replayability:replayability ->
  (unit -> pull) ->
  upload_source
(** [stream open_pull] is a pull-streaming source. [open_pull ()] opens a reader.
    [length], when present, is the exact byte length. A negative length raises
    [Invalid_argument]. [Replayable] permits opening further readers; reopening a
    [One_shot] source raises [Invalid_argument]. *)

val known_length : upload_source -> int64 option
val replayability : upload_source -> replayability
val open_pull : upload_source -> pull
(** Open a reader. Raises [Invalid_argument] when a [One_shot] source has
    already been opened. *)

type upload = {
  filename : string;
  content_type : string;
  source : upload_source;
}

module Speech_to_text : sig
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

module Text_to_speech : sig
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
