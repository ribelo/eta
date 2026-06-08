type stats = {
  mutable pulls : int;
  mutable chunks : int;
  mutable elements : int;
}

let create_stats () = { pulls = 0; chunks = 0; elements = 0 }

module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let fail error _env = Error error
  let bind f eff env =
    match eff env with
    | Ok value -> f value env
    | Error error -> Error error

  let run env eff = eff env
end

type ('err, 'a) step =
  | Chunk of 'a list
  | Done
  | Failed of 'err

type ('err, 'a) cursor = {
  pull : unit -> ('err, 'a) step;
  close : unit -> unit;
}

module Stream = struct
  type ('env, 'err, 'a) t = Stream of ('env -> stats -> ('err, 'a) cursor)

  let emit stats values =
    stats.pulls <- stats.pulls + 1;
    match values with
    | [] -> Done
    | values ->
        stats.chunks <- stats.chunks + 1;
        stats.elements <- stats.elements + List.length values;
        Chunk values

  let empty = Stream (fun _env _stats -> { pull = (fun () -> Done); close = ignore })

  let from_iterable ?(chunk_size = Services.default_chunk_size) values =
    Stream
      (fun _env stats ->
        let rest = ref values in
        let pull () =
          match !rest with
          | [] ->
              stats.pulls <- stats.pulls + 1;
              Done
          | values ->
              let chunk = Services.take chunk_size values in
              let rec drop n xs =
                if n <= 0 then xs
                else match xs with [] -> [] | _ :: xs -> drop (n - 1) xs
              in
              rest := drop chunk_size values;
              emit stats chunk
        in
        { pull; close = ignore })

  let range ?chunk_size start stop =
    from_iterable ?chunk_size (Services.range start stop)

  let resource ?chunk_size name values =
    Stream
      (fun _env stats ->
        let file = Services.open_file name values in
        let (Stream make) = from_iterable ?chunk_size file.values in
        let inner = make _env stats in
        {
          pull = inner.pull;
          close =
            (fun () ->
              inner.close ();
              if not file.closed then Services.close_file file);
        })

  let fail error =
    Stream
      (fun _env _stats ->
        let emitted = ref false in
        {
          pull =
            (fun () ->
              if !emitted then Done
              else (
                emitted := true;
                Failed error));
          close = ignore;
        })

  let map f (Stream make) =
    Stream
      (fun env stats ->
        let inner = make env stats in
        {
          pull =
            (fun () ->
              match inner.pull () with
              | Chunk values -> Chunk (List.map f values)
              | Done -> Done
              | Failed error -> Failed error);
          close = inner.close;
        })

  let rec pull_nonempty inner f =
    match inner.pull () with
    | Chunk values -> (
        match List.filter f values with
        | [] -> pull_nonempty inner f
        | values -> Chunk values)
    | Done -> Done
    | Failed error -> Failed error

  let filter f (Stream make) =
    Stream
      (fun env stats ->
        let inner = make env stats in
        { pull = (fun () -> pull_nonempty inner f); close = inner.close })

  let take n (Stream make) =
    Stream
      (fun env stats ->
        let inner = make env stats in
        let remaining = ref n in
        let closed = ref false in
        let close () =
          if not !closed then (
            closed := true;
            inner.close ())
        in
        let pull () =
          if !remaining <= 0 then (
            close ();
            Done)
          else
            match inner.pull () with
            | Chunk values ->
                let out = Services.take !remaining values in
                remaining := !remaining - List.length out;
                if !remaining <= 0 then close ();
                Chunk out
            | Done ->
                close ();
                Done
            | Failed error ->
                close ();
                Failed error
        in
        { pull; close })

  let drop n (Stream make) =
    Stream
      (fun env stats ->
        let inner = make env stats in
        let remaining = ref n in
        let rec pull () =
          match inner.pull () with
          | Chunk values when !remaining > 0 ->
              let dropped = min !remaining (List.length values) in
              remaining := !remaining - dropped;
              let rec drop n xs =
                if n <= 0 then xs
                else match xs with [] -> [] | _ :: xs -> drop (n - 1) xs
              in
              let values = drop dropped values in
              if values = [] then pull () else Chunk values
          | other -> other
        in
        { pull; close = inner.close })
end

module Sink = struct
  type ('env, 'err, 'in_, 'out) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('env, 'err, 'out) Effect.t;
    done_ : 'out -> ('env, 'err, 'out) Effect.t;
  }

  let fold f init =
    {
      init = (fun () -> init);
      step = (fun acc value -> Effect.pure (f acc value));
      done_ = Effect.pure;
    }
end

let run ?(stats = create_stats ()) stream sink =
  fun env ->
    let (Stream.Stream make) = stream in
    let cursor = make env stats in
    Fun.protect
      ~finally:cursor.close
      (fun () ->
        let rec loop acc =
          match cursor.pull () with
          | Done -> Sink.(sink.done_ acc) env
          | Failed error -> Error error
          | Chunk values -> (
              match
                List.fold_left
                  (fun acc value ->
                    match acc with
                    | Error _ as error -> error
                    | Ok acc -> Sink.(sink.step acc value) env)
                  (Ok acc) values
              with
              | Error _ as error -> error
              | Ok acc -> loop acc)
        in
        loop (sink.Sink.init ()))

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10 |> Stream.map (fun n -> n * 2) |> Stream.take 5

let program : (< >, no_error, int) Effect.t = run s (Sink.fold ( + ) 0)

let resource_program () =
  Services.reset ();
  let stream = Stream.resource "s-b2-file" [ 1; 2; 3 ] |> Stream.take 1 in
  let result = Effect.run (object end) (run stream (Sink.fold ( + ) 0)) in
  (result, Services.close_count "s-b2-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
