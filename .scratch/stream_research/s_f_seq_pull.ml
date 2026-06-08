module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let run env eff = eff env
end

module Stream = struct
  type ('env, 'err, 'a) t = unit -> 'a Seq.node

  let from_iterable values = List.to_seq values
  let range start stop = from_iterable (Services.range start stop)
  let map = Seq.map

  let rec take n stream =
    let remaining = ref n in
    fun () ->
      if !remaining <= 0 then Seq.Nil
      else
        match stream () with
        | Seq.Nil -> Seq.Nil
        | Seq.Cons (value, rest) ->
            remaining := !remaining - 1;
            Seq.Cons (value, take !remaining rest)

  let resource name values =
    let file = Services.open_file name values in
    let rec loop values () =
      match values with
      | [] ->
          Services.close_file file;
          Seq.Nil
      | value :: rest -> Seq.Cons (value, loop rest)
    in
    loop file.values
end

module Sink = struct
  let fold f init stream =
    Seq.fold_left f init stream
end

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10 |> Stream.map (fun n -> n * 2) |> Stream.take 5

let program : (< >, no_error, int) Effect.t =
  Effect.pure (Sink.fold ( + ) 0 s)

let resource_leak_program () =
  Services.reset ();
  let stream = Stream.resource "s-f-file" [ 1; 2; 3 ] |> Stream.take 1 in
  let result = Effect.run (object end) (Effect.pure (Sink.fold ( + ) 0 stream)) in
  (result, Services.close_count "s-f-file")

module type STREAM_SIG = sig
  val s : (< >, no_error, int) Stream.t
  val program : (< >, no_error, int) Effect.t
end

module _ : STREAM_SIG = struct
  let s = s
  let program = program
end
