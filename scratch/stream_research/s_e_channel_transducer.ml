module Effect = struct
  type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

  let pure value _env = Ok value
  let run env eff = eff env
end

module Channel = struct
  type ('env, 'err, 'in_elem, 'in_done, 'out_elem, 'out_done) t = {
    run :
      'env ->
      'in_elem list ->
      'in_done ->
      (('out_elem list * 'out_done), 'err) result;
  }

  let source values =
    { run = (fun _env _input () -> Ok (values, ())) }

  let map f channel =
    {
      run =
        (fun env input done_ ->
          match channel.run env input done_ with
          | Error error -> Error error
          | Ok (values, out_done) -> Ok (List.map f values, out_done));
    }

  let take n channel =
    {
      run =
        (fun env input done_ ->
          match channel.run env input done_ with
          | Error error -> Error error
          | Ok (values, out_done) -> Ok (Services.take n values, out_done));
    }

  let pipe left right =
    {
      run =
        (fun env input done_ ->
          match left.run env input done_ with
          | Error error -> Error error
          | Ok (mid, mid_done) -> right.run env mid mid_done);
    }

  let split_lines =
    {
      run =
        (fun _env chunks () ->
          let text = String.concat "" chunks in
          let len = String.length text in
          let rec loop start acc i =
            if i = len then
              let carry = String.sub text start (len - start) in
              Ok (List.rev acc, carry)
            else if text.[i] = '\n' then
              let line = String.sub text start (i - start) in
              loop (i + 1) (line :: acc) (i + 1)
            else loop start acc (i + 1)
          in
          loop 0 [] 0);
    }
end

module Sink = struct
  let fold f init values = List.fold_left f init values
end

module Stream = struct
  type ('env, 'err, 'a) t =
    | Stream :
        ('env, 'err, unit, unit, 'a, unit) Channel.t
        -> ('env, 'err, 'a) t

  let from_channel channel = Stream channel
  let range start stop = from_channel (Channel.source (Services.range start stop))
  let map f (Stream channel) = Stream (Channel.map f channel)
  let take n (Stream channel) = Stream (Channel.take n channel)

  let run (Stream channel) sink =
    fun env ->
      match channel.Channel.run env [] () with
      | Error error -> Error error
      | Ok (values, ()) -> Ok (sink values)
end

type no_error = |

let s : (< >, no_error, int) Stream.t =
  Stream.range 1 10 |> Stream.map (fun n -> n * 2) |> Stream.take 5

let program : (< >, no_error, int) Effect.t =
  Stream.run s (Sink.fold ( + ) 0)

let line_program () =
  let source = Channel.source [ "a\nb"; "\nc" ] in
  let channel = Channel.pipe source Channel.split_lines in
  channel.Channel.run (object end) [] ()

module type CHANNEL_SIG = sig
  val split_lines :
    (< >, no_error, string, unit, string, string) Channel.t

  val program : (< >, no_error, int) Effect.t
end

module _ : CHANNEL_SIG = struct
  let split_lines = Channel.split_lines
  let program = program
end
