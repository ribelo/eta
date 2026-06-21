type +'a chunk = 'a list

let default_file_chunk_size = 64 * 1024
let file_queue_capacity = 16

module Stream = struct
  type file_operation = Eta_stream_file.operation
  type file_error_kind = Eta_stream_file.error_kind
  type file_error = Eta_stream_file.error = {
    operation : file_operation;
    path : string;
    kind : file_error_kind;
    message : string;
    diagnostic : string;
  }

  let pp_file_error = Eta_stream_file.pp_error

  type ('a, 'err) t =
    | Empty : ('a, 'err) t
    | Chunk : 'a chunk -> ('a, 'err) t
    | From_effect : ('a, 'err) Eta.Effect.t -> ('a, 'err) t
    | Fail : 'err -> ('a, 'err) t
    | From_schedule :
        (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t
        -> ('out, 'err) t
    | Map : ('a, 'err) t * ('a -> 'b) -> ('b, 'err) t
    | Map_effect :
        ('a, 'err) t * ('a -> ('b, 'err) Eta.Effect.t)
        -> ('b, 'err) t
    | Tap_error :
        ('a, 'err) t * ('err -> (unit, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Filter : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Filter_map : ('a, 'err) t * ('a -> 'b option) -> ('b, 'err) t
    | Filter_map_effect :
        ('a, 'err) t * ('a -> ('b option, 'err) Eta.Effect.t)
        -> ('b, 'err) t
    | Changes_with : ('a, 'err) t * ('a -> 'a -> bool) -> ('a, 'err) t
    | Changes_with_effect :
        ('a, 'err) t * ('a -> 'a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Zip_with :
        ('a, 'err) t * ('b, 'err) t * ('a -> 'b -> 'c)
        -> ('c, 'err) t
    | Zip_with_index : ('a, 'err) t -> ('a * int, 'err) t
    | Schedule :
        ('a, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t
        * ('a, 'err) t
        -> ('a, 'err) t
    | Repeat :
        (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t
        * ('a, 'err) t
        -> ('a, 'err) t
    | Retry :
        ('err, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t
        * ('a, 'err) t
        -> ('a, 'err) t
    | Take : int * ('a, 'err) t -> ('a, 'err) t
    | Take_while : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Take_while_effect :
        ('a, 'err) t * ('a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Take_until_effect :
        ('a, 'err) t * ('a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Drop : int * ('a, 'err) t -> ('a, 'err) t
    | Drop_while : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Drop_while_effect :
        ('a, 'err) t * ('a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Drop_until : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Drop_until_effect :
        ('a, 'err) t * ('a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Scan : ('s -> 'a -> 's) * 's * ('a, 'err) t -> ('s, 'err) t
    | Grouped : int * ('a, 'err) t -> ('a list, 'err) t
    | Concat :
        ('a, 'err) t * ('a, 'err) t
        -> ('a, 'err) t
    | Flat_map :
        ('a, 'err) t * ('a -> ('b, 'err) t)
        -> ('b, 'err) t
    | Merge :
        ('a, 'err) t * ('a, 'err) t
        -> ('a, 'err) t
    | Flat_map_par :
        int * ('a, 'err) t * ('a -> ('b, 'err) t)
        -> ('b, 'err) t
    | From_eio_stream : 'a Eio.Stream.t -> ('a, 'err) t
    | From_queue : ('a, 'err) Eta.Queue.t -> ('a, 'err) t
    | From_mailbox : 'a Mailbox_internal.t -> ('a, 'err) t
    | From_mailbox_batches :
        int * 'a Mailbox_internal.t
        -> ('a list, 'err) t
    | From_file :
        {
          chunk_size : int;
          path : [> Eio.Fs.dir_ty ] Eio.Path.t;
          path_label : string;
          on_error : file_error -> 'err;
        }
        -> (bytes, 'err) t
    | Range : { start : int; stop : int } -> (int, 'err) t
    | Named : string * ('a, 'err) t -> ('a, 'err) t
    | Fn :
        string * int * int * int * string * ('a, 'err) t
        -> ('a, 'err) t

  let empty = Empty
  let succeed value = Chunk [ value ]
  let from_chunk chunk = Chunk chunk
  let from_iterable values = Chunk values
  let range ~start ~stop =
    if stop < start then invalid_arg "Eta_stream.range: stop must be >= start";
    Range { start; stop }
  let from_effect eff = From_effect eff
  let fail error = Fail error
  let from_schedule schedule = From_schedule schedule
  let map (f) stream = Map (stream, f)
  let map_effect (f) stream = Map_effect (stream, f)
  let tap (f) stream =
    map_effect
      (fun value -> Eta.Effect.map (fun () -> value) (f value))
      stream
  let tap_error (f) stream = Tap_error (stream, f)
  let filter (f) stream = Filter (stream, f)
  let filter_map (f) stream = Filter_map (stream, f)
  let filter_map_effect (f) stream = Filter_map_effect (stream, f)
  let changes stream = Changes_with (stream, ( = ))
  let changes_with (f) stream = Changes_with (stream, f)
  let changes_with_effect (f) stream = Changes_with_effect (stream, f)
  let zip left right = Zip_with (left, right, fun left right -> (left, right))
  let zip_with (f) left right = Zip_with (left, right, f)
  let zip_with_index stream = Zip_with_index stream
  let schedule schedule stream = Schedule (schedule, stream)
  let repeat schedule stream = Repeat (schedule, stream)
  let retry schedule stream = Retry (schedule, stream)
  let take n stream = Take (n, stream)
  let take_while (f) stream = Take_while (stream, f)
  let take_while_effect (f) stream = Take_while_effect (stream, f)
  let take_until_effect (f) stream = Take_until_effect (stream, f)
  let drop n stream = Drop (n, stream)
  let drop_while (f) stream = Drop_while (stream, f)
  let drop_while_effect (f) stream = Drop_while_effect (stream, f)
  let drop_until (f) stream = Drop_until (stream, f)
  let drop_until_effect (f) stream = Drop_until_effect (stream, f)
  let scan (f) init stream = Scan (f, init, stream)
  let grouped n stream =
    if n <= 0 then invalid_arg "Eta_stream.grouped: n must be > 0";
    Grouped (n, stream)
  let concat left right = Concat (left, right)
  let flat_map (f) stream = Flat_map (stream, f)
  let merge left right = Merge (left, right)

  let flat_map_par ~max_concurrency (f) stream =
    if max_concurrency <= 0 then
      invalid_arg "Eta_stream.flat_map_par: max_concurrency must be > 0";
    Flat_map_par (max_concurrency, stream, f)

  let from_eio_stream stream = From_eio_stream stream
  let from_queue queue = From_queue queue

  let from_file_map_error ?(chunk_size = default_file_chunk_size) ~on_error path =
    if chunk_size <= 0 then
      invalid_arg "Eta_stream.from_file: chunk_size must be > 0";
    let path_label = Format.asprintf "%a" Eio.Path.pp path in
    From_file { chunk_size; path; path_label; on_error }

  let from_file ?chunk_size path =
    from_file_map_error ?chunk_size
      ~on_error:(fun error -> `File_error error)
      path
  let named name stream = Named (name, stream)
  let fn (file, line, col_start, col_end) name stream =
    Fn (file, line, col_start, col_end, name, stream)
end

module Mailbox = struct
  include Mailbox_internal

  let to_stream mailbox = Stream.From_mailbox mailbox
  let to_batch_stream ~max mailbox =
    if max <= 0 then invalid_arg "Eta_stream.Mailbox.to_batch_stream: max must be > 0";
    Stream.From_mailbox_batches (max, mailbox)
end

module Drain_counter = Drain_counter_internal

module Sink = struct
  type ('in_, 'out, 'err) t = {
    init : (unit -> 'out);
    step : ('out -> 'in_ -> ('out, 'err) Eta.Effect.t);
    pure_step : ('out -> 'in_ -> 'out) option;
    done_ : ('out -> ('out, 'err) Eta.Effect.t);
  }

  let fold (f) init =
    {
      init = (fun () -> init);
      step = (fun acc value -> Eta.Effect.pure (f acc value));
      pure_step = Some f;
      done_ = Eta.Effect.pure;
    }

  let fold_effect (f) init =
    { init = (fun () -> init); step = f; pure_step = None; done_ = Eta.Effect.pure }

  let collect_to_list =
    {
      init = (fun () -> []);
      step = (fun acc value -> Eta.Effect.pure (value :: acc));
      pure_step = Some (fun acc value -> value :: acc);
      done_ = (fun acc -> Eta.Effect.pure (List.rev acc));
    }

  let count =
    {
      init = (fun () -> 0);
      step = (fun acc _ -> Eta.Effect.pure (acc + 1));
      pure_step = Some (fun acc _ -> acc + 1);
      done_ = Eta.Effect.pure;
    }

  let drain =
    {
      init = (fun () -> ());
      step = (fun () _ -> Eta.Effect.unit);
      pure_step = Some (fun () _ -> ());
      done_ = Eta.Effect.pure;
    }
end

type ('acc, 'a, 'err) folder = {
  emit : ('acc -> 'a -> ('acc * bool, 'err) Eta.Effect.t);
}

type ('a, 'err) queue_event = Item of 'a | Done | Failed of 'err
type ('a, 'err) zip_event =
  | Zip_item of 'a * (unit, 'err) Eta.Channel.t
  | Zip_done
  | Zip_failed of 'err
type 'a outer_event = Outer_item of 'a | Outer_done

let internal_channel_closed name =
  invalid_arg (name ^ ": internal channel closed")

let send_channel name channel value =
  Eta.Channel.send channel value
  |> Eta.Effect.catch (function
       | `Closed -> Eta.Effect.sync (fun () -> internal_channel_closed name)
       | `Closed_with_error error -> Eta.Effect.fail error)

let recv_channel name channel =
  Eta.Channel.recv channel
  |> Eta.Effect.catch (function
       | `Closed -> Eta.Effect.sync (fun () -> internal_channel_closed name)
       | `Closed_with_error error -> Eta.Effect.fail error)

let rec drain_channel channel =
  Eta.Channel.try_recv channel
  |> Eta.Effect.bind (function
       | `Item _ -> drain_channel channel
       | `Empty | `Closed | `Closed_with_error _ -> Eta.Effect.unit)

let rec drive_schedule_step = function
  | Eta.Schedule.Complete (decision, driver) ->
      Eta.Effect.pure (decision, driver)
  | Eta.Schedule.Hook (hook, resume) ->
      hook |> Eta.Effect.bind (fun () -> drive_schedule_step (resume ()))

let schedule_step ~input driver =
  Eta.Effect.bind
    (fun now_ms ->
      Eta.Schedule.step_plan ~now_ms ~input driver |> drive_schedule_step)
    Eta.Effect.now

let make_file_error ~operation ~path cause =
  Eta_stream_file.make_error ~operation ~path cause

let rec fold_values :
    type err acc a.
    a list ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
 fun values acc folder ->
  match values with
  | [] -> Eta.Effect.pure (acc, true)
  | _ ->
      let rec loop values acc =
        match values with
        | [] -> Eta.Effect.pure (acc, true)
        | value :: rest ->
            Eta.Effect.bind
              (fun (acc, keep_going) ->
                if keep_going then loop rest acc
                else Eta.Effect.pure (acc, false))
              (folder.emit acc value)
      in
      loop values acc

and try_fold_pure :
    type err acc a.
    (a, err) Stream.t -> (acc -> a -> acc) -> acc -> acc option =
 fun stream step init ->
  let open Stream in
  let exception Bail in
  let rec go : type b. (b, err) Stream.t -> (acc -> b -> acc) -> acc -> acc =
    fun s k acc ->
      match s with
      | Empty -> acc
      | Chunk values -> List.fold_left k acc values
      (* Fused source-specific loops: avoid composed closure indirection *)
      | Range { start; stop } ->
          let rec loop i acc =
            if i > stop then acc
            else
              let acc = k acc i in
              (* Stop at [stop] without computing [i + 1], which would overflow
                 to [min_int] when [stop = max_int] and emit out-of-range
                 values. *)
              if i = stop then acc else loop (i + 1) acc
          in
          loop start acc
      | Map (Range { start; stop }, f) ->
          let rec loop i acc =
            if i > stop then acc
            else
              let acc = k acc (f i) in
              if i = stop then acc else loop (i + 1) acc
          in
          loop start acc
      | Filter (Range { start; stop }, pred) ->
          let rec loop i acc =
            if i > stop then acc
            else
              let acc = if pred i then k acc i else acc in
              if i = stop then acc else loop (i + 1) acc
          in
          loop start acc
      | Filter (Map (Range { start; stop }, f), pred) ->
          let rec loop i acc =
            if i > stop then acc
            else
              let y = f i in
              let acc = if pred y then k acc y else acc in
              if i = stop then acc else loop (i + 1) acc
          in
          loop start acc
      | Map (Chunk values, f) ->
          let rec loop acc = function
            | [] -> acc
            | x :: xs -> loop (k acc (f x)) xs
          in
          loop acc values
      | Filter (Chunk values, pred) ->
          let rec loop acc = function
            | [] -> acc
            | x :: xs -> loop (if pred x then k acc x else acc) xs
          in
          loop acc values
      | Filter (Map (Chunk values, f), pred) ->
          let rec loop acc = function
            | [] -> acc
            | x :: xs ->
                let y = f x in
                loop (if pred y then k acc y else acc) xs
          in
          loop acc values
      (* Generic combinators *)
      | Map (inner, f) -> go inner (fun a x -> k a (f x)) acc
      | Tap_error (inner, _) -> go inner k acc
      | Filter (inner, pred) ->
          go inner (fun a x -> if pred x then k a x else a) acc
      | Drop (n, inner) ->
          let remaining = ref (max 0 n) in
          go inner
            (fun a x ->
              if !remaining > 0 then (decr remaining; a) else k a x)
            acc
      | Take (n, Merge (Chunk left, Chunk right)) ->
          if n <= 0 then acc
          else
            let rec take_list remaining acc = function
              | [] -> (acc, remaining)
              | _ when remaining <= 0 -> (acc, 0)
              | x :: xs -> take_list (remaining - 1) (k acc x) xs
            in
            let acc, remaining = take_list n acc left in
            if remaining <= 0 then acc else fst (take_list remaining acc right)
      | Take (n, inner) ->
          if n <= 0 then acc
          else
            let exception Done of acc in
            let remaining = ref n in
            (try
               go inner
                 (fun a x ->
                   if !remaining <= 0 then raise (Done a)
                   else (decr remaining; k a x))
                 acc
             with Done a -> a)
      | Scan (f, s_init, inner) ->
          let state = ref s_init in
          go inner
            (fun a x ->
              let next = f !state x in
              state := next;
              k a next)
            acc
      | Concat (left, right) -> go right k (go left k acc)
      | Merge (left, right) -> go right k (go left k acc)
      | Flat_map (inner, f) -> go inner (fun a x -> go (f x) k a) acc
      | Flat_map_par (_, inner, f) -> go inner (fun a x -> go (f x) k a) acc
      | Named (_, inner) | Fn (_, _, _, _, _, inner) -> go inner k acc
      | _ -> raise Bail
  in
  try Some (go stream step init) with Bail -> None

and fold_stream :
    type err acc a.
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
 fun stream acc folder ->
  match stream with
  | Stream.Empty -> Eta.Effect.pure (acc, true)
  | Chunk values -> fold_values values acc folder
  | From_effect eff -> Eta.Effect.bind (fun value -> folder.emit acc value) eff
  | Fail error -> Eta.Effect.fail error
  | From_schedule schedule -> fold_from_schedule schedule acc folder
  | Map (inner, f) ->
      fold_stream inner acc {
        emit = (fun acc value -> folder.emit acc (f value));
      }
  | Map_effect (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              Eta.Effect.bind (fun mapped -> folder.emit acc mapped) (f value));
        }
  | Tap_error (inner, observe) ->
      fold_stream inner acc folder
      |> Eta.Effect.catch (fun error ->
             observe error
             |> Eta.Effect.bind (fun () -> Eta.Effect.fail error))
  | Filter (inner, f) ->
      fold_stream inner acc
        {
          emit =
              (fun acc value ->
                if f value then folder.emit acc value
                else Eta.Effect.pure (acc, true));
        }
  | Filter_map (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              match f value with
              | Some mapped -> folder.emit acc mapped
              | None -> Eta.Effect.pure (acc, true));
        }
  | Filter_map_effect (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              Eta.Effect.bind
                (function
                  | Some mapped -> folder.emit acc mapped
                  | None -> Eta.Effect.pure (acc, true))
                (f value));
        }
  | Changes_with (inner, equivalent) ->
      let previous = ref None in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              match !previous with
              | Some last when equivalent last value ->
                  Eta.Effect.pure (acc, true)
              | Some _ | None ->
                  Eta.Effect.map
                    (fun (acc, keep_going) ->
                      previous := Some value;
                      (acc, keep_going))
                    (folder.emit acc value));
        }
  | Changes_with_effect (inner, equivalent) ->
      let previous = ref None in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              match !previous with
              | None ->
                  Eta.Effect.map
                    (fun (acc, keep_going) ->
                      previous := Some value;
                      (acc, keep_going))
                    (folder.emit acc value)
              | Some last ->
                  Eta.Effect.bind
                    (fun same ->
                      if same then Eta.Effect.pure (acc, true)
                      else
                        Eta.Effect.map
                          (fun (acc, keep_going) ->
                            previous := Some value;
                            (acc, keep_going))
                          (folder.emit acc value))
                    (equivalent last value));
        }
  | Zip_with (left, right, f) -> fold_zip_with left right f acc folder
  | Zip_with_index inner ->
      let next_index = ref (Some 0) in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              match !next_index with
              | None ->
                  Eta.Effect.sync (fun () ->
                      invalid_arg "Eta_stream.zip_with_index: index overflow")
              | Some index ->
                  let next =
                    if index = max_int then None else Some (index + 1)
                  in
                  Eta.Effect.map
                    (fun (acc, keep_going) ->
                      next_index := next;
                      (acc, keep_going))
                    (folder.emit acc (value, index)));
        }
  | Schedule (schedule, inner) -> fold_schedule schedule inner acc folder
  | Repeat (schedule, inner) -> fold_repeat schedule inner acc folder
  | Retry (schedule, inner) -> fold_retry schedule inner acc folder
  | Take (n, inner) ->
      if n <= 0 then Eta.Effect.pure (acc, false)
      else
        let remaining = ref n in
        fold_stream inner acc
          {
            emit =
              (fun acc value ->
                if !remaining <= 0 then Eta.Effect.pure (acc, false)
                else (
                  decr remaining;
                  Eta.Effect.map
                    (fun (acc, keep_going) ->
                      (acc, keep_going && !remaining > 0))
                    (folder.emit acc value)));
          }
  | Take_while (inner, predicate) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if predicate value then folder.emit acc value
              else Eta.Effect.pure (acc, false));
        }
  | Take_while_effect (inner, predicate) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              Eta.Effect.bind
                (fun keep ->
                  if keep then folder.emit acc value
                  else Eta.Effect.pure (acc, false))
                (predicate value));
        }
  | Take_until_effect (inner, predicate) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              Eta.Effect.bind
                (fun (acc, keep_going) ->
                  if not keep_going then Eta.Effect.pure (acc, false)
                  else
                    Eta.Effect.map
                      (fun stop -> (acc, not stop))
                      (predicate value))
                (folder.emit acc value));
        }
  | Drop (n, inner) ->
      let remaining = ref (max 0 n) in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !remaining > 0 then (
                decr remaining;
                Eta.Effect.pure (acc, true))
              else folder.emit acc value);
        }
  | Drop_while (inner, predicate) ->
      let dropping = ref true in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !dropping && predicate value then Eta.Effect.pure (acc, true)
              else (
                dropping := false;
                folder.emit acc value));
        }
  | Drop_while_effect (inner, predicate) ->
      let dropping = ref true in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !dropping then
                Eta.Effect.bind
                  (fun drop ->
                    if drop then Eta.Effect.pure (acc, true)
                    else (
                      dropping := false;
                      folder.emit acc value))
                  (predicate value)
              else folder.emit acc value);
        }
  | Drop_until (inner, predicate) ->
      let dropping = ref true in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !dropping then (
                if predicate value then dropping := false;
                Eta.Effect.pure (acc, true))
              else folder.emit acc value);
        }
  | Drop_until_effect (inner, predicate) ->
      let dropping = ref true in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !dropping then
                Eta.Effect.bind
                  (fun stop ->
                    if stop then dropping := false;
                    Eta.Effect.pure (acc, true))
                  (predicate value)
              else folder.emit acc value);
        }
  | Scan (f, init, inner) ->
      let state = ref init in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              let next = f !state value in
              state := next;
              folder.emit acc next);
        }
  | Grouped (n, inner) ->
      let batch = ref [] in
      let batch_len = ref 0 in
      let flush acc =
        match !batch with
        | [] -> Eta.Effect.pure (acc, true)
        | values ->
            batch := [];
            batch_len := 0;
            folder.emit acc (List.rev values)
      in
      Eta.Effect.bind
        (fun (acc, keep_going) ->
          if keep_going then flush acc else Eta.Effect.pure (acc, false))
        (fold_stream inner acc
           {
             emit =
               (fun acc value ->
                 batch := value :: !batch;
                 incr batch_len;
                 if !batch_len >= n then flush acc
                 else Eta.Effect.pure (acc, true));
           })
  | Concat (left, right) ->
      Eta.Effect.bind
        (fun (acc, keep_going) ->
          if keep_going then fold_stream right acc folder
          else Eta.Effect.pure (acc, false))
        (fold_stream left acc folder)
  | Flat_map (inner, f) ->
      fold_stream inner acc
        {
          emit = (fun acc value -> fold_stream (f value) acc folder);
        }
  | Merge (left, right) -> fold_merge left right acc folder
  | Flat_map_par (max_concurrency, inner, f) ->
      fold_flat_map_par ~max_concurrency inner f acc folder
  | From_eio_stream stream ->
      let rec loop acc =
        Eta.Effect.bind
          (fun value ->
            Eta.Effect.bind
              (fun (acc, keep_going) ->
                if keep_going then loop acc else Eta.Effect.pure (acc, false))
              (folder.emit acc value))
          (Eta.Effect.named "Eta_stream.from_eio_stream.take" (Eta.Effect.sync (fun () ->
               Eio.Stream.take stream)))
      in
      loop acc
  | From_queue queue ->
      let rec loop acc =
        Eta.Queue.recv queue
        |> Eta.Effect.map (fun value -> `Item value)
        |> Eta.Effect.catch (function
             | `Closed -> Eta.Effect.pure `Closed
             | `Closed_with_error error -> Eta.Effect.fail error)
        |> Eta.Effect.bind (function
             | `Closed -> Eta.Effect.pure (acc, true)
             | `Item value ->
                 folder.emit acc value
                 |> Eta.Effect.bind (fun (acc, keep_going) ->
                        if keep_going then loop acc
                        else Eta.Effect.pure (acc, false)))
      in
      loop acc
  | From_mailbox mailbox ->
      let rec loop acc =
        Eta.Effect.bind
          (function
            | Mailbox_internal.Take_closed -> Eta.Effect.pure (acc, true)
            | Mailbox_internal.Item value ->
                Eta.Effect.bind
                  (fun (acc, keep_going) ->
                    if keep_going then loop acc
                    else Eta.Effect.pure (acc, false))
                  (folder.emit acc value))
          (Eta.Effect.named "Eta_stream.Mailbox_internal.take" (Eta.Effect.sync (fun () ->
               Mailbox_internal.take mailbox)))
      in
      loop acc
  | From_mailbox_batches (max, mailbox) ->
      let rec loop acc =
        Eta.Effect.bind
          (function
            | Mailbox_internal.Take_closed -> Eta.Effect.pure (acc, true)
            | Mailbox_internal.Item values ->
                Eta.Effect.bind
                  (fun (acc, keep_going) ->
                    if keep_going then loop acc
                    else Eta.Effect.pure (acc, false))
                  (folder.emit acc values))
          (Eta.Effect.named "Eta_stream.Mailbox_internal.take_batch" (Eta.Effect.sync (fun () ->
               Mailbox_internal.take_batch mailbox max)))
      in
      loop acc
  | From_file { chunk_size; path; path_label; on_error } ->
      let queue = Eio.Stream.create file_queue_capacity in
      let stopped = Atomic.make false in
      let producer =
        Eta.Effect.named "Eta_stream.from_file.read" (Eta.Effect.sync (fun () ->
            let operation = ref `Open in
            try
              Eio.Switch.run ~name:"Eta_stream.from_file" @@ fun sw ->
              let flow = Eio.Path.open_in ~sw path in
              operation := `Read;
              let buffer = Cstruct.create chunk_size in
              let rec read_loop () =
                if Atomic.get stopped then ()
                else
                  match Eio.Flow.single_read flow buffer with
                  | bytes_read ->
                      if bytes_read > 0 then (
                        let chunk =
                          Cstruct.to_bytes (Cstruct.sub buffer 0 bytes_read)
                        in
                        Eio.Stream.add queue (Item chunk);
                        read_loop ())
                  | exception End_of_file -> operation := `Close
              in
              read_loop ();
              if not (Atomic.get stopped) then Eio.Stream.add queue Done
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if not (Atomic.get stopped) then
                  Eio.Stream.add queue
                    (Failed
                       (on_error
                          (make_file_error ~operation:!operation
                             ~path:path_label exn)))))
      in
      Eta.Supervisor.scoped
        {
          run =
            (fun (type s) sup ->
              let open Eta.Supervisor.Scope in
              let* (child : (s, err, unit) Eta.Supervisor.child) =
                start sup (lift producer)
              in
              let rec consume acc =
                let* event =
                  lift (Eta.Effect.sync (fun () -> Eio.Stream.take queue))
                in
                match event with
                | Done ->
                    let* () = await child in
                    pure (acc, true)
                | Failed error ->
                    let () = Atomic.set stopped true in
                    fail error
                | Item chunk ->
                    let* acc, keep_going = lift (folder.emit acc chunk) in
                    if keep_going then consume acc
                    else
                      let () = Atomic.set stopped true in
                      let* () = cancel child in
                      pure (acc, false)
              in
              consume acc);
        }
  | Range { start; stop } ->
      let rec loop i acc =
        if i > stop then Eta.Effect.pure (acc, true)
        else
          Eta.Effect.bind
            (fun (acc, keep_going) ->
              (* Stop at [stop] without computing [i + 1], which would overflow
                 to [min_int] when [stop = max_int]. *)
              if keep_going && i <> stop then loop (i + 1) acc
              else Eta.Effect.pure (acc, keep_going))
            (folder.emit acc i)
      in
      loop start acc
  | Named (name, inner) -> Eta.Effect.named name (fold_stream inner acc folder)
  | Fn (file, line, col_start, col_end, name, inner) ->
      Eta.Effect.fn (file, line, col_start, col_end) name
        (fold_stream inner acc folder)

and fold_from_schedule :
    type err acc out.
    (unit, out, (unit, err) Eta.Effect.t) Eta.Schedule.t ->
    acc ->
    (acc, out, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun schedule acc folder ->
  let rec loop acc driver =
    schedule_step ~input:() driver
    |> Eta.Effect.bind (function
         | Eta.Schedule.Done _, _ -> Eta.Effect.pure (acc, true)
         | Eta.Schedule.Continue metadata, next_driver ->
             Eta.Effect.sleep metadata.delay
             |> Eta.Effect.bind (fun () ->
                    folder.emit acc metadata.output)
             |> Eta.Effect.bind (fun (acc, keep_going) ->
                    if keep_going then loop acc next_driver
                    else Eta.Effect.pure (acc, false)))
  in
  loop acc (Eta.Schedule.start schedule)

and fold_schedule :
    type err acc a out.
    (a, out, (unit, err) Eta.Effect.t) Eta.Schedule.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun schedule inner acc folder ->
  let driver = ref (Eta.Schedule.start schedule) in
  let pending_delay = ref None in
  let sleep_pending () =
    match !pending_delay with
    | None -> Eta.Effect.unit
    | Some delay ->
        pending_delay := None;
        Eta.Effect.sleep delay
  in
  fold_stream inner acc
    {
      emit =
        (fun acc value ->
          sleep_pending ()
          |> Eta.Effect.bind (fun () -> schedule_step ~input:value !driver)
          |> Eta.Effect.bind (function
               | Eta.Schedule.Done _, _ -> Eta.Effect.pure (acc, false)
               | Eta.Schedule.Continue metadata, next_driver ->
                   driver := next_driver;
                   pending_delay := Some metadata.delay;
                   folder.emit acc value));
    }

and fold_repeat :
    type err acc a out.
    (unit, out, (unit, err) Eta.Effect.t) Eta.Schedule.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun schedule inner acc folder ->
  let rec loop acc driver =
    fold_stream inner acc folder
    |> Eta.Effect.bind (fun (acc, keep_going) ->
           if not keep_going then Eta.Effect.pure (acc, false)
           else
             schedule_step ~input:() driver
             |> Eta.Effect.bind (function
                  | Eta.Schedule.Done _, _ -> Eta.Effect.pure (acc, true)
                  | Eta.Schedule.Continue metadata, next_driver ->
                      Eta.Effect.sleep metadata.delay
                      |> Eta.Effect.bind (fun () -> loop acc next_driver)))
  in
  loop acc (Eta.Schedule.start schedule)

and fold_retry :
    type err acc a out.
    (err, out, (unit, err) Eta.Effect.t) Eta.Schedule.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun schedule inner acc folder ->
  let driver = ref (Eta.Schedule.start schedule) in
  let reset_driver () = driver := Eta.Schedule.start schedule in
  let rec loop acc =
    let latest_acc = ref acc in
    fold_stream inner acc
      {
        emit =
          (fun acc value ->
            reset_driver ();
            folder.emit acc value
            |> Eta.Effect.map (fun (acc, keep_going) ->
                   latest_acc := acc;
                   (acc, keep_going)));
      }
    |> Eta.Effect.catch (fun error ->
           schedule_step ~input:error !driver
           |> Eta.Effect.bind (function
                | Eta.Schedule.Done _, _ -> Eta.Effect.fail error
                | Eta.Schedule.Continue metadata, next_driver ->
                    driver := next_driver;
                    Eta.Effect.sleep metadata.delay
                    |> Eta.Effect.bind (fun () -> loop !latest_acc)))
  in
  loop acc

and fold_zip_with :
    type err acc a b c.
    (a, err) Stream.t ->
    (b, err) Stream.t ->
    (a -> b -> c) ->
    acc ->
    (acc, c, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun left right f acc folder ->
  let left_queue = Eta.Channel.create ~capacity:1 () in
  let right_queue = Eta.Channel.create ~capacity:1 () in
  let stopped = Atomic.make false in
  let publish_failure error =
    Eta.Effect.named "Eta_stream.zip.failed"
      (if Atomic.compare_and_set stopped false true then
         drain_channel left_queue
         |> Eta.Effect.bind (fun () -> drain_channel right_queue)
         |> Eta.Effect.bind (fun () ->
                send_channel "Eta_stream.zip.left" left_queue
                  (Zip_failed error))
         |> Eta.Effect.bind (fun () ->
                send_channel "Eta_stream.zip.right" right_queue
                  (Zip_failed error))
       else Eta.Effect.unit)
  in
  let signal_right_done_to_left () =
    Eta.Channel.try_send left_queue Zip_done
    |> Eta.Effect.map (function
         | `Sent | `Full -> ()
         | `Closed | `Closed_with_error _ -> ())
  in
  let producer name queue ~signal_left stream =
    let publish_done =
      Eta.Effect.named (name ^ ".done")
        (Eta.Effect.sync (fun () -> Atomic.get stopped)
        |> Eta.Effect.bind (fun stopped ->
               if stopped then Eta.Effect.unit
               else
                 send_channel name queue Zip_done
                 |> Eta.Effect.bind (fun () ->
                        if signal_left then signal_right_done_to_left ()
                        else Eta.Effect.unit)))
    in
    Eta.Effect.bind
      (fun () -> publish_done)
      (Eta.Effect.map ignore
         (fold_stream stream ()
            {
              emit =
                (fun () value ->
                  if Atomic.get stopped then Eta.Effect.pure ((), false)
                  else
                    let ack = Eta.Channel.create ~capacity:1 () in
                    Eta.Effect.map
                      (fun () -> ((), not (Atomic.get stopped)))
                      (send_channel name queue (Zip_item (value, ack))
                      |> Eta.Effect.bind (fun () ->
                             recv_channel (name ^ ".ack") ack)));
            }))
    |> Eta.Effect.catch (fun error -> publish_failure error)
  in
  Eta.Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Eta.Supervisor.Scope in
          let* (left_child : (s, err, unit) Eta.Supervisor.child) =
            start sup
              (lift
                 (producer "Eta_stream.zip.left" left_queue ~signal_left:false
                    left))
          in
          let* (right_child : (s, err, unit) Eta.Supervisor.child) =
            start sup
              (lift
                 (producer "Eta_stream.zip.right" right_queue ~signal_left:true
                    right))
          in
          let cancel_both () =
            let* () = cancel left_child in
            cancel right_child
          in
          let recv_left =
            recv_channel "Eta_stream.zip.left" left_queue
          in
          let recv_right =
            recv_channel "Eta_stream.zip.right" right_queue
          in
          let ack_left ack =
            send_channel "Eta_stream.zip.left.ack" ack ()
          in
          let ack_right ack =
            send_channel "Eta_stream.zip.right.ack" ack ()
          in
          let rec stop acc keep_going =
            let () = Atomic.set stopped true in
            let* () = cancel_both () in
            pure (acc, keep_going)
          and emit_pair acc left_value left_ack right_value right_ack =
            let* combined = lift (Eta.Effect.sync (fun () -> f left_value right_value)) in
            let* acc, keep_going = lift (folder.emit acc combined) in
            if keep_going then
              let* () = lift (ack_left left_ack) in
              let* () = lift (ack_right right_ack) in
              consume acc
            else
              let () = Atomic.set stopped true in
              let* () = lift (ack_left left_ack) in
              let* () = lift (ack_right right_ack) in
              let* () = cancel_both () in
              pure (acc, false)
          and handle_right acc left_value left_ack = function
            | Zip_failed error ->
                let () = Atomic.set stopped true in
                fail error
            | Zip_done -> stop acc true
            | Zip_item (right_value, right_ack) ->
                emit_pair acc left_value left_ack right_value right_ack
          and consume acc =
            let* left_event = lift recv_left in
            match left_event with
            | Zip_failed error ->
                let () = Atomic.set stopped true in
                fail error
            | Zip_done -> stop acc true
            | Zip_item (left_value, left_ack) ->
                let* right_event = lift recv_right in
                handle_right acc left_value left_ack right_event
          in
          consume acc);
    }

and fold_merge :
    type err acc a.
    (a, err) Stream.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun left right acc folder ->
  let queue = Eta.Channel.create ~capacity:1024 () in
  let stopped = Atomic.make false in
  let producer stream =
    let publish_failure error =
      Eta.Effect.named "Eta_stream.merge.failed"
        (if Atomic.compare_and_set stopped false true then
           drain_channel queue
           |> Eta.Effect.bind (fun () ->
                  send_channel "Eta_stream.merge" queue (Failed error))
         else Eta.Effect.unit)
    in
    let add_item value =
      if Atomic.get stopped then Eta.Effect.pure false
      else
        send_channel "Eta_stream.merge" queue (Item value)
        |> Eta.Effect.map (fun () -> true)
    in
    let publish_done =
      Eta.Effect.named "Eta_stream.merge.done"
        (Eta.Effect.sync (fun () -> Atomic.get stopped)
        |> Eta.Effect.bind (fun stopped ->
               if stopped then Eta.Effect.unit
               else send_channel "Eta_stream.merge" queue Done))
    in
    Eta.Effect.bind
      (fun () -> publish_done)
      (Eta.Effect.map ignore
         (fold_stream stream ()
            {
              emit =
                (fun () value ->
                  if Atomic.get stopped then Eta.Effect.pure ((), false)
                  else
                    Eta.Effect.map (fun added -> ((), added))
                      (add_item value));
            }))
    |> Eta.Effect.catch (fun error ->
           publish_failure error)
  in
  Eta.Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Eta.Supervisor.Scope in
          let* (left_child : (s, err, unit) Eta.Supervisor.child) =
            start sup (lift (producer left))
          in
          let* (right_child : (s, err, unit) Eta.Supervisor.child) =
            start sup (lift (producer right))
          in
          let cancel_both () =
            let* () = cancel left_child in
            cancel right_child
          in
          let await_both () =
            let* () = await left_child in
            await right_child
          in
          let rec consume remaining acc =
            if remaining = 0 then
              let* () = await_both () in
              pure (acc, true)
            else
              let* event =
                lift (recv_channel "Eta_stream.merge" queue)
              in
              match event with
              | Done -> consume (remaining - 1) acc
              | Failed error ->
                  let () = Atomic.set stopped true in
                  fail error
              | Item value ->
                  let* acc, keep_going = lift (folder.emit acc value) in
                  if keep_going then consume remaining acc
                  else
                    let () = Atomic.set stopped true in
                    let* () = cancel_both () in
                    pure (acc, false)
          in
          consume 2 acc);
    }

and fold_flat_map_par :
    type err acc a b.
    max_concurrency:int ->
    (a, err) Stream.t ->
    (a -> (b, err) Stream.t) ->
    acc ->
    (acc, b, err) folder ->
    (acc * bool, err) Eta.Effect.t =
fun ~max_concurrency inner f acc folder ->
  let outer_queue = Eta.Channel.create ~capacity:max_concurrency () in
  let output_queue = Eta.Channel.create ~capacity:1024 () in
  let stopped = Atomic.make false in
  let rec send_outer_done n =
    if n <= 0 then Eta.Effect.unit
    else
      send_channel "Eta_stream.flat_map_par.outer" outer_queue Outer_done
      |> Eta.Effect.bind (fun () -> send_outer_done (n - 1))
  in
  let wake_workers () =
    drain_channel outer_queue
    |> Eta.Effect.bind (fun () -> send_outer_done max_concurrency)
  in
  let publish_failure error =
    Eta.Effect.named "Eta_stream.flat_map_par.failed"
      (if Atomic.compare_and_set stopped false true then
         drain_channel output_queue
         |> Eta.Effect.bind (fun () ->
                send_channel "Eta_stream.flat_map_par.output" output_queue
                  (Failed error))
         |> Eta.Effect.bind (fun () -> wake_workers ())
       else Eta.Effect.unit)
  in
  let outer_producer =
    let publish_done =
      Eta.Effect.named "Eta_stream.flat_map_par.outer_done"
        (Eta.Effect.sync (fun () -> Atomic.get stopped)
        |> Eta.Effect.bind (fun stopped ->
               if stopped then Eta.Effect.unit
               else
                 send_channel "Eta_stream.flat_map_par.outer" outer_queue
                   Outer_done))
    in
    Eta.Effect.bind
      (fun () -> publish_done)
      (Eta.Effect.map ignore
         (fold_stream inner ()
            {
              emit =
                (fun () value ->
                  if Atomic.get stopped then Eta.Effect.pure ((), false)
                  else
                    Eta.Effect.map
                      (fun () -> ((), true))
                      (send_channel "Eta_stream.flat_map_par.outer"
                         outer_queue (Outer_item value)));
            }))
    |> Eta.Effect.catch (fun error ->
           publish_failure error)
  in
  let worker =
    let publish_done =
      Eta.Effect.named "Eta_stream.flat_map_par.worker_done"
        (Eta.Effect.sync (fun () -> Atomic.get stopped)
        |> Eta.Effect.bind (fun stopped ->
               if stopped then Eta.Effect.unit
               else
                 send_channel "Eta_stream.flat_map_par.output" output_queue
                   Done))
    in
    let rec loop () =
      Eta.Effect.bind
        (function
          | Outer_done ->
              Eta.Effect.named "Eta_stream.flat_map_par.rebroadcast_done"
                (Eta.Effect.sync (fun () -> Atomic.get stopped)
                |> Eta.Effect.bind (fun stopped ->
                       if stopped then Eta.Effect.unit
                       else
                         send_channel "Eta_stream.flat_map_par.outer"
                           outer_queue Outer_done))
          | Outer_item value ->
              Eta.Effect.bind
                (fun _ -> loop ())
                (Eta.Effect.map ignore
                   (fold_stream (f value) ()
                      {
                        emit =
                          (fun () item ->
                            if Atomic.get stopped then
                              Eta.Effect.pure ((), false)
                            else
                              Eta.Effect.map
                                (fun () -> ((), true))
                                (send_channel "Eta_stream.flat_map_par.output"
                                   output_queue (Item item)));
                      })))
        (recv_channel "Eta_stream.flat_map_par.outer" outer_queue)
    in
    Eta.Effect.bind (fun () -> publish_done) (loop ())
    |> Eta.Effect.catch (fun error ->
           publish_failure error)
  in
  Eta.Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Eta.Supervisor.Scope in
          let* (outer_child : (s, err, unit) Eta.Supervisor.child) =
            start sup (lift outer_producer)
          in
          let rec start_workers n acc =
            if n <= 0 then pure (List.rev acc)
            else
              let* (child : (s, err, unit) Eta.Supervisor.child) =
                start sup (lift worker)
              in
              start_workers (n - 1) (child :: acc)
          in
          let rec cancel_all = function
            | [] -> pure ()
            | child :: rest ->
                let* () = cancel child in
                cancel_all rest
          in
          let rec await_all = function
            | [] -> pure ()
            | child :: rest ->
                let* () = await child in
                await_all rest
          in
          let* workers = start_workers max_concurrency [] in
          let stop_outer_producer () =
            lift
              (Eta.Effect.named "Eta_stream.flat_map_par.stop_outer"
                 (Eta.Effect.sync (fun () -> Atomic.set stopped true)
                 |> Eta.Effect.bind (fun () -> drain_channel outer_queue)))
          in
          let cancel_everything () =
            let () = Atomic.set stopped true in
            let* () = cancel outer_child in
            let* () =
              lift
                (Eta.Effect.named "Eta_stream.flat_map_par.wake_workers"
                   (wake_workers ()))
            in
            cancel_all workers
          in
          let await_everything () =
            let* () = stop_outer_producer () in
            let* () = await_all workers in
            await outer_child
          in
          let rec consume remaining_workers acc =
            if remaining_workers = 0 then
              let* () = await_everything () in
              pure (acc, true)
            else
              let* event =
                lift (recv_channel "Eta_stream.flat_map_par.output" output_queue)
              in
              match event with
              | Done -> consume (remaining_workers - 1) acc
              | Failed error ->
                  let () = Atomic.set stopped true in
                  fail error
              | Item value ->
                  let* acc, keep_going = lift (folder.emit acc value) in
                  if keep_going then consume remaining_workers acc
                  else
                    let* () = cancel_everything () in
                    pure (acc, false)
          in
          consume max_concurrency acc);
    }

and effect_list :
    type err a. (a, err) Stream.t -> (a list, err) Eta.Effect.t =
 fun stream ->
  Eta.Effect.map
    (fun (values, _) -> List.rev values)
    (fold_stream stream []
       { emit = (fun acc value -> Eta.Effect.pure (value :: acc, true)) })

let run : type a b err. (a, err) Stream.t -> (a, b, err) Sink.t -> (b, err) Eta.Effect.t =
 fun stream sink ->
  let init = sink.Sink.init () in
  match sink.Sink.pure_step with
  | Some step ->
      (match try_fold_pure stream step init with
       | Some acc -> sink.Sink.done_ acc
       | None ->
           Eta.Effect.bind
             (fun (acc, _) -> sink.Sink.done_ acc)
             (fold_stream stream init
                {
                  emit =
                    (fun acc value ->
                      Eta.Effect.map (fun acc -> (acc, true))
                        (sink.Sink.step acc value));
                }))
  | None ->
      Eta.Effect.bind
        (fun (acc, _) -> sink.Sink.done_ acc)
        (fold_stream stream init
           {
             emit =
               (fun acc value ->
                 Eta.Effect.map (fun acc -> (acc, true))
                   (sink.Sink.step acc value));
           })

let run_collect stream = run stream Sink.collect_to_list
let run_drain stream = run stream Sink.drain

let run_for_each (f) stream =
  run stream
    (Sink.fold_effect
       (fun () value ->
         f value |> Eta.Effect.map (fun () -> ()))
       ())

let run_fold (f) init stream = run stream (Sink.fold f init)
let run_count stream = run stream Sink.count
