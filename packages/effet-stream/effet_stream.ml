type +'a chunk = 'a list

module Stream = struct
  type ('env, 'err, 'a) t =
    | Empty : ('env, 'err, 'a) t
    | Chunk : 'a chunk -> ('env, 'err, 'a) t
    | From_effect : ('env, 'err, 'a) Effet.Effect.t -> ('env, 'err, 'a) t
    | Fail : 'err -> ('env, 'err, 'a) t
    | Map : ('env, 'err, 'a) t * ('a -> 'b) -> ('env, 'err, 'b) t
    | Map_effect :
        ('env, 'err, 'a) t * ('a -> ('env, 'err, 'b) Effet.Effect.t)
        -> ('env, 'err, 'b) t
    | Filter : ('env, 'err, 'a) t * ('a -> bool) -> ('env, 'err, 'a) t
    | Take : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Drop : int * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Scan : ('s -> 'a -> 's) * 's * ('env, 'err, 'a) t -> ('env, 'err, 's) t
    | Concat :
        ('env, 'err, 'a) t * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) t
    | Flat_map :
        ('env, 'err, 'a) t * ('a -> ('env, 'err, 'b) t)
        -> ('env, 'err, 'b) t
    | From_eio_stream : 'a Eio.Stream.t -> ('env, 'err, 'a) t
    | From_file : _ Eio.Path.t -> ('env, 'err, bytes) t
    | Named : string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Fn :
        string * int * int * int * string * ('env, 'err, 'a) t
        -> ('env, 'err, 'a) t

  let empty = Empty
  let succeed value = Chunk [ value ]
  let from_chunk chunk = Chunk chunk
  let from_iterable values = Chunk values
  let from_effect eff = From_effect eff
  let fail error = Fail error
  let map f stream = Map (stream, f)
  let map_effect f stream = Map_effect (stream, f)
  let filter f stream = Filter (stream, f)
  let take n stream = Take (n, stream)
  let drop n stream = Drop (n, stream)
  let scan f init stream = Scan (f, init, stream)
  let concat left right = Concat (left, right)
  let flat_map f stream = Flat_map (stream, f)
  let merge left right = Concat (left, right)
  let flat_map_par ~max_concurrency:_ f stream = Flat_map (stream, f)
  let from_eio_stream stream = From_eio_stream stream
  let from_file path = From_file path
  let named name stream = Named (name, stream)
  let fn (file, line, col_start, col_end) name stream =
    Fn (file, line, col_start, col_end, name, stream)
end

module Sink = struct
  type ('env, 'err, 'in_, 'out) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('env, 'err, 'out) Effet.Effect.t;
    done_ : 'out -> ('env, 'err, 'out) Effet.Effect.t;
  }

  let fold f init =
    {
      init = (fun () -> init);
      step = (fun acc value -> Effet.Effect.pure (f acc value));
      done_ = Effet.Effect.pure;
    }

  let fold_effect f init =
    { init = (fun () -> init); step = f; done_ = Effet.Effect.pure }

  let collect_to_list =
    {
      init = (fun () -> []);
      step = (fun acc value -> Effet.Effect.pure (value :: acc));
      done_ = (fun acc -> Effet.Effect.pure (List.rev acc));
    }

  let count =
    {
      init = (fun () -> 0);
      step = (fun acc _ -> Effet.Effect.pure (acc + 1));
      done_ = Effet.Effect.pure;
    }

  let drain =
    {
      init = (fun () -> ());
      step = (fun () _ -> Effet.Effect.unit);
      done_ = Effet.Effect.pure;
    }
end

let rec effect_list :
    type env err a. (env, err, a) Stream.t -> (env, err, a list) Effet.Effect.t =
 fun stream ->
  match stream with
  | Stream.Empty -> Effet.Effect.pure []
  | Chunk values -> Effet.Effect.pure values
  | From_effect eff -> Effet.Effect.map (fun value -> [ value ]) eff
  | Fail error -> Effet.Effect.fail error
  | Map (inner, f) -> Effet.Effect.map (List.map f) (effect_list inner)
  | Map_effect (inner, f) ->
      Effet.Effect.bind
        (fun values ->
          List.fold_right
            (fun value acc ->
              Effet.Effect.bind
                (fun mapped ->
                  Effet.Effect.map (fun rest -> mapped :: rest) acc)
                (f value))
            values (Effet.Effect.pure []))
        (effect_list inner)
  | Filter (inner, f) -> Effet.Effect.map (List.filter f) (effect_list inner)
  | Take (n, inner) ->
      Effet.Effect.map
        (fun values ->
          let rec loop n acc = function
            | _ when n <= 0 -> List.rev acc
            | [] -> List.rev acc
            | value :: rest -> loop (n - 1) (value :: acc) rest
          in
          loop n [] values)
        (effect_list inner)
  | Drop (n, inner) ->
      Effet.Effect.map
        (fun values ->
          let rec loop n values =
            if n <= 0 then values
            else match values with [] -> [] | _ :: rest -> loop (n - 1) rest
          in
          loop n values)
        (effect_list inner)
  | Scan (f, init, inner) ->
      Effet.Effect.map
        (fun values ->
          let _, values =
            List.fold_left
              (fun (state, acc) value ->
                let state = f state value in
                (state, state :: acc))
              (init, []) values
          in
          List.rev values)
        (effect_list inner)
  | Concat (left, right) ->
      Effet.Effect.bind
        (fun left_values ->
          Effet.Effect.map
            (fun right_values -> left_values @ right_values)
            (effect_list right))
        (effect_list left)
  | Flat_map (inner, f) ->
      Effet.Effect.bind
        (fun values ->
          List.fold_right
            (fun value acc ->
              Effet.Effect.bind
                (fun head ->
                  Effet.Effect.map (fun tail -> head @ tail) acc)
                (effect_list (f value)))
            values (Effet.Effect.pure []))
        (effect_list inner)
  | From_eio_stream _ -> Effet.Effect.pure []
  | From_file _ -> Effet.Effect.pure []
  | Named (name, inner) -> Effet.Effect.named name (effect_list inner)
  | Fn (file, line, col_start, col_end, name, inner) ->
      Effet.Effect.fn (file, line, col_start, col_end) name (effect_list inner)

let run stream sink =
  Effet.Effect.bind
    (fun values ->
      let init = sink.Sink.init () in
      let folded =
        List.fold_left
          (fun acc value ->
            Effet.Effect.bind
              (fun acc -> sink.Sink.step acc value)
              acc)
          (Effet.Effect.pure init) values
      in
      Effet.Effect.bind sink.Sink.done_ folded)
    (effect_list stream)

let run_collect stream = run stream Sink.collect_to_list
let run_drain stream = run stream Sink.drain
