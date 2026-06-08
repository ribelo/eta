module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let fail error _env = Error error

  let bind f eff env =
    match eff env with
    | Ok value -> f value env
    | Error error -> Error error

  let map f eff env = Result.map f (eff env)
  let run env eff = eff env
end

module Channel = struct
  type open_scope = [ `Open ]

  type ('env, 'err, 'out, 'done_) t =
    | Source :
        {
          chunk_size : int;
          run : 'env -> limit:int option -> (('out list list * 'done_), 'err) result;
        }
        -> ('env, 'err, 'out, 'done_) t
    | Map :
        ('env, 'err, 'a, 'done_) t * ('a -> 'b)
        -> ('env, 'err, 'b, 'done_) t
    | Take : int * ('env, 'err, 'a, 'done_) t -> ('env, 'err, 'a, 'done_) t

  let flatten chunks = List.concat chunks
  let chunk chunk_size xs = Services.chunks_of_list chunk_size xs

  let rec run :
      type env err out done_.
      env ->
      limit:int option ->
      (env, err, out, done_) t ->
      ((out list list * done_), err) result =
   fun env ~limit channel ->
    match channel with
    | Source source -> source.run env ~limit
    | Map (inner, f) ->
        run env ~limit inner
        |> Result.map (fun (chunks, done_) -> (List.map (List.map f) chunks, done_))
    | Take (n, inner) ->
        let limit =
          match limit with
          | None -> Some n
          | Some outer -> Some (min n outer)
        in
        run env ~limit inner
        |> Result.map (fun (chunks, done_) ->
               let values = flatten chunks |> Services.take n in
               (chunk Services.default_chunk_size values, done_))

  let from_range start stop =
    Source
      {
        chunk_size = Services.default_chunk_size;
        run =
          (fun _env ~limit ->
            let values = Services.range start stop in
            let values =
              match limit with
              | None -> values
              | Some n -> Services.take n values
            in
            Ok (chunk Services.default_chunk_size values, ()));
      }

  let scoped_file ~(scope : open_scope) name values =
    let _ = scope in
    Source
      {
        chunk_size = Services.default_chunk_size;
        run =
          (fun _env ~limit ->
            let file = Services.open_file name values in
            let values =
              match limit with
              | None -> file.values
              | Some n -> Services.take n file.values
            in
            Services.close_file file;
            Ok (chunk Services.default_chunk_size values, ()));
      }

  let map f channel = Map (channel, f)
  let take n channel = Take (n, channel)
end

module Sink = struct
  type ('env, 'err, 'in_, 'out) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('env, 'err, 'out) Effect.t;
    done_ : 'out -> ('env, 'err, 'out) Effect.t;
  }

  let fold f init = { init = (fun () -> init); step = (fun acc x -> Effect.pure (f acc x)); done_ = Effect.pure }
end

module Stream = struct
  type ('env, 'err, 'a) t = Stream : ('env, 'err, 'a, unit) Channel.t -> ('env, 'err, 'a) t

  let from_channel channel = Stream channel
  let range start stop = from_channel (Channel.from_range start stop)
  let map f (Stream channel) = Stream (Channel.map f channel)
  let take n (Stream channel) = Stream (Channel.take n channel)
  let scoped_file ~scope name values = from_channel (Channel.scoped_file ~scope name values)

  let run (Stream channel) sink =
    fun env ->
      match Channel.run env ~limit:None channel with
      | Error error -> Error error
      | Ok (chunks, ()) ->
          let rec fold acc = function
            | [] -> Sink.(sink.done_ acc) env
            | x :: rest -> (
                match Sink.(sink.step acc x) env with
                | Error error -> Error error
                | Ok acc -> fold acc rest)
          in
          fold (sink.Sink.init ()) (List.concat chunks)
end

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10
  |> Stream.map (fun n -> n * 2)
  |> Stream.take 5

let program : (< >, no_error, int) Effect.t = Stream.run s (Sink.fold ( + ) 0)

let resource_program () =
  Services.reset ();
  let scope = (`Open : Channel.open_scope) in
  let stream =
    Stream.scoped_file ~scope "s-a-file" [ 1; 2; 3 ]
    |> Stream.take 1
  in
  let result = Effect.run (object end) (Stream.run stream (Sink.fold ( + ) 0)) in
  (result, Services.close_count "s-a-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
