module Effect = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Sync : string * ('env -> 'a) -> ('env, _, 'a) t
    | Attempt : string * ('env -> ('a, 'err) result) -> ('env, 'err, 'a) t
    | Bind :
        ('env, 'err, 'a) t * ('a -> ('env, 'err, 'b) t)
        -> ('env, 'err, 'b) t

  let pure value = Pure value
  let fail error = Fail error
  let sync name f = Sync (name, f)
  let attempt name f = Attempt (name, f)
  let bind f eff = Bind (eff, f)
  let map f eff = bind (fun value -> pure (f value)) eff

  let rec run : type env err a. env -> (env, err, a) t -> (a, err) result =
   fun env eff ->
    match eff with
    | Pure value -> Ok value
    | Fail error -> Error error
    | Sync (_, f) -> Ok (f env)
    | Attempt (_, f) -> f env
    | Bind (inner, f) -> (
        match run env inner with
        | Ok value -> run env (f value)
        | Error error -> Error error)
end

module Stream = struct
  type ('env, 'err, 'a) t =
    | From_chunks : 'a list list -> (_, _, 'a) t
    | From_effect : ('env, 'err, 'a) Effect.t -> ('env, 'err, 'a) t
    | Resource :
        {
          name : string;
          values : int list;
        }
        -> (_, _, int) t
    | Map : ('env, 'err, 'a) t * ('a -> 'b) -> ('env, 'err, 'b) t
    | Filter : ('env, 'err, 'a) t * ('a -> bool) -> ('env, 'err, 'a) t
    | Take : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Drop : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t

  let from_chunks chunks = From_chunks chunks
  let range start stop = From_chunks (Services.chunks_of_list Services.default_chunk_size (Services.range start stop))
  let map f stream = Map (stream, f)
  let filter f stream = Filter (stream, f)
  let take n stream = Take (n, stream)
  let drop n stream = Drop (n, stream)
  let fail error = Fail error
  let from_effect eff = From_effect eff
  let resource name values = Resource { name; values }

  let rec eval :
      type env err a.
      env ->
      limit:int option ->
      (env, err, a) t ->
      (a list list, err) result =
   fun env ~limit stream ->
    let rechunk values = Services.chunks_of_list Services.default_chunk_size values in
    match stream with
    | From_chunks chunks ->
        let values = List.concat chunks in
        let values =
          match limit with
          | None -> values
          | Some n -> Services.take n values
        in
        Ok (rechunk values)
    | From_effect eff -> (
        match Effect.run env eff with
        | Ok value -> Ok [ [ value ] ]
        | Error error -> Error error)
    | Resource { name; values } ->
        let file = Services.open_file name values in
        let values =
          match limit with
          | None -> file.values
          | Some n -> Services.take n file.values
        in
        Services.close_file file;
        Ok (rechunk values)
    | Map (inner, f) ->
        eval env ~limit inner
        |> Result.map (fun chunks -> List.map (List.map f) chunks)
    | Filter (inner, f) ->
        eval env ~limit:None inner
        |> Result.map (fun chunks ->
               let values = List.concat chunks |> List.filter f in
               let values =
                 match limit with
                 | None -> values
                 | Some n -> Services.take n values
               in
               rechunk values)
    | Take (n, inner) ->
        let limit =
          match limit with
          | None -> Some n
          | Some outer -> Some (min n outer)
        in
        eval env ~limit inner
    | Drop (n, inner) ->
        eval env ~limit:None inner
        |> Result.map (fun chunks ->
               let rec drop n xs =
                 if n <= 0 then xs
                 else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
               in
               let values = drop n (List.concat chunks) in
               let values =
                 match limit with
                 | None -> values
                 | Some n -> Services.take n values
               in
               rechunk values)
    | Fail error -> Error error
end

module Sink = struct
  type ('env, 'err, 'in_, 'out) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('env, 'err, 'out) Effect.t;
    done_ : 'out -> ('env, 'err, 'out) Effect.t;
  }

  let fold f init = { init = (fun () -> init); step = (fun acc x -> Effect.pure (f acc x)); done_ = Effect.pure }
  let collect_to_list = { init = (fun () -> []); step = (fun acc x -> Effect.pure (x :: acc)); done_ = (fun acc -> Effect.pure (List.rev acc)) }
  let count = { init = (fun () -> 0); step = (fun acc _ -> Effect.pure (acc + 1)); done_ = Effect.pure }
end

let run stream sink =
  Effect.attempt "stream.run" (fun env ->
    match Stream.eval env ~limit:None stream with
    | Error error -> Error error
    | Ok chunks ->
        let rec fold acc = function
          | [] -> Sink.(sink.done_ acc) |> Effect.run env
          | x :: rest -> (
              match Sink.(sink.step acc x) |> Effect.run env with
              | Ok acc -> fold acc rest
              | Error error -> Error error)
        in
        fold (sink.Sink.init ()) (List.concat chunks))

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10
  |> Stream.map (fun n -> n * 2)
  |> Stream.take 5

let program : (< >, no_error, int) Effect.t = run s (Sink.fold ( + ) 0)

let resource_program () =
  Services.reset ();
  let stream = Stream.resource "s-b-file" [ 1; 2; 3 ] |> Stream.take 1 in
  let result = Effect.run (object end) (run stream (Sink.fold ( + ) 0)) in
  (result, Services.close_count "s-b-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
