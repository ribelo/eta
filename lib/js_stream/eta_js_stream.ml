type +'a chunk = 'a list

type ('a, 'err) pull_result =
  | Done
  | Chunk of 'a list
  | Error of 'err Eta_js.Cause.t

type ('a, 'err) stream = unit -> (('a, 'err) pull_result, 'err) Eta_js.Effect.t

module Stream = struct
  type ('a, 'err) t = ('a, 'err) stream

  let empty () = Eta_js.Effect.pure Done

  let succeed v =
    let sent = ref false in
    fun () ->
      if !sent then Eta_js.Effect.pure Done
      else begin
        sent := true;
        Eta_js.Effect.pure (Chunk [ v ])
      end

  let from_chunk xs =
    let sent = ref false in
    fun () ->
      if !sent then Eta_js.Effect.pure Done
      else begin
        sent := true;
        Eta_js.Effect.pure (Chunk xs)
      end

  let[@inline always] from_iterable xs =
    let remaining = ref xs in
    fun () ->
      match !remaining with
      | [] -> Eta_js.Effect.pure Done
      | xs ->
          remaining := [];
          Eta_js.Effect.pure (Chunk xs)

  let range ~start ~stop =
    from_iterable (List.init (max 0 (stop - start)) (fun i -> start + i))

  let from_effect eff =
    let sent = ref false in
    fun () ->
      if !sent then Eta_js.Effect.pure Done
      else begin
        sent := true;
        Eta_js.Effect.map (fun v -> Chunk [ v ]) eff
      end

  let fail err =
    let sent = ref false in
    fun () ->
      if !sent then Eta_js.Effect.pure Done
      else begin
        sent := true;
        Eta_js.Effect.pure (Error (Eta_js.Cause.fail err))
      end

  let map f source () =
    Eta_js.Effect.map
      (function
        | Chunk xs -> Chunk (List.map f xs)
        | Done -> Done
        | Error cause -> Error cause)
      (source ())

  let map_effect f source () =
    Eta_js.Effect.bind
      (function
        | Chunk xs ->
            Eta_js.Effect.map (fun ys -> Chunk ys)
              (Eta_js.Effect.all (List.map f xs))
        | Done -> Eta_js.Effect.pure Done
        | Error cause -> Eta_js.Effect.pure (Error cause))
      (source ())

  let filter pred source () =
    Eta_js.Effect.map
      (function
        | Chunk xs -> Chunk (List.filter pred xs)
        | Done -> Done
        | Error cause -> Error cause)
      (source ())

  let take n source =
    if n <= 0 then empty
    else
      let remaining = ref n in
      fun () ->
        if !remaining <= 0 then Eta_js.Effect.pure Done
        else
          Eta_js.Effect.map
            (function
              | Chunk xs ->
                  let len = List.length xs in
                  if len <= !remaining then begin
                    remaining := !remaining - len;
                    Chunk xs
                  end else begin
                    let rec take_drop n acc = function
                      | [] -> (List.rev acc, [])
                      | h :: t when n > 0 -> take_drop (n - 1) (h :: acc) t
                      | rest -> (List.rev acc, rest)
                    in
                    let taken, _rest = take_drop !remaining [] xs in
                    remaining := 0;
                    Chunk taken
                  end
              | Done -> Done
              | Error cause -> Error cause)
            (source ())

  let drop n source =
    if n <= 0 then source
    else
      let remaining = ref n in
      fun () ->
        if !remaining <= 0 then source ()
        else
          Eta_js.Effect.map
            (function
              | Chunk xs ->
                  let len = List.length xs in
                  if len <= !remaining then begin
                    remaining := !remaining - len;
                    Chunk []
                  end else begin
                    let rec drop n = function
                      | [] -> []
                      | _ :: t when n > 0 -> drop (n - 1) t
                      | rest -> rest
                    in
                    let rest = drop !remaining xs in
                    remaining := 0;
                    Chunk rest
                  end
              | Done -> Done
              | Error cause -> Error cause)
            (source ())

  let scan f initial source =
    let acc = ref initial in
    fun () ->
      Eta_js.Effect.map
        (function
          | Chunk xs ->
              let results = ref [] in
              List.iter
                (fun x ->
                  acc := f !acc x;
                  results := !acc :: !results)
                xs;
              Chunk (List.rev !results)
          | Done -> Done
          | Error cause -> Error cause)
        (source ())

  let grouped n source =
    if n <= 0 then invalid_arg "Eta_js_stream.Stream.grouped: n must be > 0";
    let buffer = ref [] in
    fun () ->
      let rec emit_or_fill () =
        if List.length !buffer >= n then begin
          let rec take_drop n acc = function
            | [] -> (List.rev acc, [])
            | h :: t when n > 0 -> take_drop (n - 1) (h :: acc) t
            | rest -> (List.rev acc, rest)
          in
          let group, rest = take_drop n [] !buffer in
          buffer := rest;
          Eta_js.Effect.pure (Chunk [ group ])
        end else
          Eta_js.Effect.bind
            (function
              | Done ->
                  if !buffer <> [] then begin
                    let group = !buffer in
                    buffer := [];
                    Eta_js.Effect.pure (Chunk [ group ])
                  end else Eta_js.Effect.pure Done
              | Chunk xs ->
                  buffer := !buffer @ xs;
                  emit_or_fill ()
              | Error cause -> Eta_js.Effect.pure (Error cause))
            (source ())
      in
      emit_or_fill ()

  let concat left right =
    let switched = ref false in
    let right_done = ref false in
    fun () ->
      if !right_done then Eta_js.Effect.pure Done
      else if !switched then
        Eta_js.Effect.bind
          (function
            | Done ->
                right_done := true;
                Eta_js.Effect.pure Done
            | Chunk _ as other -> Eta_js.Effect.pure other
            | Error _ as other -> Eta_js.Effect.pure other)
          (right ())
      else
        Eta_js.Effect.bind
          (function
            | Done ->
                switched := true;
                right ()
            | Chunk _ as other -> Eta_js.Effect.pure other
            | Error _ as other -> Eta_js.Effect.pure other)
          (left ())

  let flat_map f source =
    let inner = ref None in
    let rec next () =
      match !inner with
      | Some stream ->
          Eta_js.Effect.bind
            (function
              | Done ->
                  inner := None;
                  next ()
              | Chunk _ as other -> Eta_js.Effect.pure other
              | Error _ as other -> Eta_js.Effect.pure other)
            (stream ())
      | None ->
          Eta_js.Effect.bind
            (function
              | Chunk xs ->
                  let streams = List.map f xs in
                  (match streams with
                  | [] -> next ()
                  | first :: rest ->
                      inner := Some (List.fold_left (fun acc s -> concat acc s) first rest);
                      next ())
              | Done -> Eta_js.Effect.pure Done
              | Error cause -> Eta_js.Effect.pure (Error cause))
            (source ())
    in
    fun () -> next ()
end

module Sink = struct
  type ('in_, 'out, 'err) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('out, 'err) Eta_js.Effect.t;
    extract : 'out -> ('out, 'err) Eta_js.Effect.t;
  }

  let fold f init =
    {
      init = (fun () -> init);
      step = (fun acc x -> Eta_js.Effect.pure (f acc x));
      extract = (fun acc -> Eta_js.Effect.pure acc);
    }

  let fold_effect f init =
    {
      init = (fun () -> init);
      step = f;
      extract = (fun acc -> Eta_js.Effect.pure acc);
    }

  let collect_to_list =
    {
      init = (fun () -> []);
      step = (fun acc x -> Eta_js.Effect.pure (x :: acc));
      extract = (fun acc -> Eta_js.Effect.pure (List.rev acc));
    }

  let count =
    {
      init = (fun () -> 0);
      step = (fun acc _ -> Eta_js.Effect.pure (acc + 1));
      extract = (fun acc -> Eta_js.Effect.pure acc);
    }

  let drain =
    {
      init = (fun () -> ());
      step = (fun () _ -> Eta_js.Effect.pure ());
      extract = (fun () -> Eta_js.Effect.pure ());
    }
end

let fail_cause cause =
  Eta_js.Effect.Expert.make ~leaf_name:"eta_js_stream.fail_cause" @@ fun _ ->
  Eta_js.Exit.error cause

let run (source : ('a, 'err) stream) sink =
  let rec loop acc =
    Eta_js.Effect.bind
      (function
        | Done -> sink.Sink.extract acc
        | Chunk xs ->
            let rec process_chunk acc = function
              | [] -> loop acc
              | x :: rest ->
                  Eta_js.Effect.bind
                    (fun acc' -> process_chunk acc' rest)
                    (sink.Sink.step acc x)
            in
            process_chunk acc xs
        | Error cause -> fail_cause cause)
      (source ())
  in
  loop (sink.Sink.init ())

let run_collect (source : ('a, 'err) stream) = run source Sink.collect_to_list
let run_drain (source : ('a, 'err) stream) = run source Sink.drain
