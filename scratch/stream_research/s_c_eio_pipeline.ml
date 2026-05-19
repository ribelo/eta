module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let run env eff = eff env
end

type 'a item =
  | Value of 'a
  | Done

module Stream = struct
  type ('env, 'err, 'a) t =
    | Source : (unit -> 'a list) -> (_, _, 'a) t
    | Resource :
        {
          name : string;
          values : 'a list;
        }
        -> (_, _, 'a) t
    | Map : ('env, 'err, 'a) t * ('a -> 'b) -> ('env, 'err, 'b) t
    | Take : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t

  let range start stop = Source (fun () -> Services.range start stop)
  let resource name values = Resource { name; values }
  let map f stream = Map (stream, f)
  let take n stream = Take (n, stream)

  let rec spawn :
      type env err a.
      sw:Eio.Switch.t -> (env, err, a) t -> a item Eio.Stream.t =
   fun ~sw stream ->
    let out = Eio.Stream.create 16 in
    let emit values =
      List.iter (fun value -> Eio.Stream.add out (Value value)) values;
      Eio.Stream.add out Done
    in
    Eio.Fiber.fork ~sw (fun () ->
        match stream with
        | Source produce -> emit (produce ())
        | Resource { name; values } ->
            let file = Services.open_file name values in
            Fun.protect
              ~finally:(fun () -> Services.close_file file)
              (fun () -> emit file.values)
        | Map (inner, f) ->
            let input = spawn ~sw inner in
            let rec loop () =
              match Eio.Stream.take input with
              | Done -> Eio.Stream.add out Done
              | Value value ->
                  Eio.Stream.add out (Value (f value));
                  loop ()
            in
            loop ()
        | Take (n, inner) ->
            let input = spawn ~sw inner in
            let rec loop remaining =
              if remaining <= 0 then Eio.Stream.add out Done
              else
                match Eio.Stream.take input with
                | Done -> Eio.Stream.add out Done
                | Value value ->
                    Eio.Stream.add out (Value value);
                    loop (remaining - 1)
            in
            loop n);
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

let run stream sink =
  fun _env ->
    Eio.Switch.run @@ fun sw ->
    let input = Stream.spawn ~sw stream in
    let rec loop acc =
      match Eio.Stream.take input with
      | Done -> Ok (sink.Sink.done_ acc)
      | Value value -> loop (sink.Sink.step acc value)
    in
    loop (sink.Sink.init ())

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10
  |> Stream.map (fun n -> n * 2)
  |> Stream.take 5

let program : (< >, no_error, int) Effect.t = run s (Sink.fold ( + ) 0)

let resource_program () =
  Services.reset ();
  let stream = Stream.resource "s-c-file" [ 1; 2; 3 ] |> Stream.take 1 in
  let result = Effect.run (object end) (run stream (Sink.fold ( + ) 0)) in
  (result, Services.close_count "s-c-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
