type stats = {
  mutable fibers : int;
  mutable chunks_sent : int;
  mutable elements_sent : int;
}

let create_stats () = { fibers = 0; chunks_sent = 0; elements_sent = 0 }

module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let run env eff = eff env
end

type ('err, 'a) item =
  | Chunk of 'a list
  | Done
  | Failed of 'err

module Stream = struct
  type ('env, 'err, 'a) t =
    | From_iterable : int * 'a list -> (_, _, 'a) t
    | Resource : int * string * 'a list -> (_, _, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Map : ('env, 'err, 'a) t * ('a -> 'b) -> ('env, 'err, 'b) t
    | Filter : ('env, 'err, 'a) t * ('a -> bool) -> ('env, 'err, 'a) t
    | Take : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t

  let from_iterable ?(chunk_size = Services.default_chunk_size) values =
    From_iterable (chunk_size, values)

  let range ?chunk_size start stop =
    from_iterable ?chunk_size (Services.range start stop)

  let resource ?(chunk_size = Services.default_chunk_size) name values =
    Resource (chunk_size, name, values)

  let fail error = Fail error
  let map f stream = Map (stream, f)
  let filter f stream = Filter (stream, f)
  let take n stream = Take (n, stream)

  let add_chunk stats out values =
    match values with
    | [] -> ()
    | values ->
        stats.chunks_sent <- stats.chunks_sent + 1;
        stats.elements_sent <- stats.elements_sent + List.length values;
        Eio.Stream.add out (Chunk values)

  let emit_iterable stats out chunk_size values =
    Services.chunks_of_list chunk_size values
    |> List.iter (add_chunk stats out);
    Eio.Stream.add out Done

  let fork stats ~sw f =
    stats.fibers <- stats.fibers + 1;
    Eio.Fiber.fork ~sw f

  let rec spawn :
      type env err a.
      stats:stats -> sw:Eio.Switch.t -> (env, err, a) t -> (err, a) item Eio.Stream.t =
   fun ~stats ~sw stream ->
    let out = Eio.Stream.create 1 in
    fork stats ~sw (fun () ->
        match stream with
        | From_iterable (chunk_size, values) ->
            emit_iterable stats out chunk_size values
        | Resource (chunk_size, name, values) ->
            let file = Services.open_file name values in
            Fun.protect
              ~finally:(fun () -> Services.close_file file)
              (fun () -> emit_iterable stats out chunk_size file.values)
        | Fail error ->
            Eio.Stream.add out (Failed error);
            Eio.Stream.add out Done
        | Map (inner, f) ->
            let input = spawn ~stats ~sw inner in
            let rec loop () =
              match Eio.Stream.take input with
              | Chunk values ->
                  add_chunk stats out (List.map f values);
                  loop ()
              | Done -> Eio.Stream.add out Done
              | Failed error ->
                  Eio.Stream.add out (Failed error);
                  Eio.Stream.add out Done
            in
            loop ()
        | Filter (inner, f) ->
            let input = spawn ~stats ~sw inner in
            let rec loop () =
              match Eio.Stream.take input with
              | Chunk values ->
                  add_chunk stats out (List.filter f values);
                  loop ()
              | Done -> Eio.Stream.add out Done
              | Failed error ->
                  Eio.Stream.add out (Failed error);
                  Eio.Stream.add out Done
            in
            loop ()
        | Take (n, inner) ->
            let input = spawn ~stats ~sw inner in
            let remaining = ref n in
            let rec loop () =
              if !remaining <= 0 then Eio.Stream.add out Done
              else
                match Eio.Stream.take input with
                | Chunk values ->
                    let values = Services.take !remaining values in
                    remaining := !remaining - List.length values;
                    add_chunk stats out values;
                    if !remaining <= 0 then Eio.Stream.add out Done else loop ()
                | Done -> Eio.Stream.add out Done
                | Failed error ->
                    Eio.Stream.add out (Failed error);
                    Eio.Stream.add out Done
            in
            loop ());
    out
end

module Sink = struct
  type ('env, 'err, 'in_, 'out) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> 'out;
    done_ : 'out -> 'out;
  }

  let fold f init = { init = (fun () -> init); step = f; done_ = Fun.id }
end

let run ?(stats = create_stats ()) stream sink =
  fun _env ->
    let result = ref None in
    let exception Stop in
    (try
       Eio.Switch.run @@ fun sw ->
       let input = Stream.spawn ~stats ~sw stream in
       let rec loop acc =
         match Eio.Stream.take input with
         | Chunk values -> loop (List.fold_left sink.Sink.step acc values)
         | Done ->
             result := Some (Ok (sink.Sink.done_ acc));
             raise Stop
         | Failed error ->
             result := Some (Error error);
             raise Stop
       in
       loop (sink.Sink.init ())
     with Stop -> ());
    match !result with
    | Some result -> result
    | None -> failwith "s_d_eio_chunked: run exited without a result"

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10 |> Stream.map (fun n -> n * 2) |> Stream.take 5

let program : (< >, no_error, int) Effect.t = run s (Sink.fold ( + ) 0)

let resource_program () =
  Services.reset ();
  let stream = Stream.resource "s-d-file" [ 1; 2; 3 ] |> Stream.take 1 in
  let result = Effect.run (object end) (run stream (Sink.fold ( + ) 0)) in
  (result, Services.close_count "s-d-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
