type +'a chunk = 'a list

let default_file_chunk_size = 64 * 1024
let file_queue_capacity = 16

module Stream = struct
  type file_operation = [ `Close | `Open | `Read ]

  type file_error_kind =
    [ `Already_exists
    | `File_too_large
    | `Io
    | `Not_found
    | `Not_native
    | `Permission_denied
    | `Unexpected ]

  type file_error = {
    operation : file_operation;
    path : string;
    kind : file_error_kind;
    message : string;
    cause : exn;
  }

  let pp_file_operation ppf = function
    | `Open -> Format.pp_print_string ppf "open"
    | `Read -> Format.pp_print_string ppf "read"
    | `Close -> Format.pp_print_string ppf "close"

  let pp_file_error_kind ppf = function
    | `Already_exists -> Format.pp_print_string ppf "already_exists"
    | `File_too_large -> Format.pp_print_string ppf "file_too_large"
    | `Io -> Format.pp_print_string ppf "io"
    | `Not_found -> Format.pp_print_string ppf "not_found"
    | `Not_native -> Format.pp_print_string ppf "not_native"
    | `Permission_denied -> Format.pp_print_string ppf "permission_denied"
    | `Unexpected -> Format.pp_print_string ppf "unexpected"

  let pp_file_error ppf error =
    Format.fprintf ppf "%a %s failed (%a): %s" pp_file_operation
      error.operation error.path pp_file_error_kind error.kind error.message

  type ('a, 'err) t =
    | Empty : ('a, 'err) t
    | Chunk : 'a chunk -> ('a, 'err) t
    | From_effect : ('a, 'err) Eta.Effect.t -> ('a, 'err) t
    | Fail : 'err -> ('a, 'err) t
    | Map : ('a, 'err) t * ('a -> 'b) -> ('b, 'err) t
    | Map_effect :
        ('a, 'err) t * ('a -> ('b, 'err) Eta.Effect.t)
        -> ('b, 'err) t
    | Filter : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Take : int * ('a, 'err) t -> ('a, 'err) t
    | Take_until_effect :
        ('a, 'err) t * ('a -> (bool, 'err) Eta.Effect.t)
        -> ('a, 'err) t
    | Drop : int * ('a, 'err) t -> ('a, 'err) t
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
    | Named : string * ('a, 'err) t -> ('a, 'err) t
    | Fn :
        string * int * int * int * string * ('a, 'err) t
        -> ('a, 'err) t

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
  let take_until_effect f stream = Take_until_effect (stream, f)
  let drop n stream = Drop (n, stream)
  let scan f init stream = Scan (f, init, stream)
  let grouped n stream =
    if n <= 0 then invalid_arg "Stream.grouped: n must be > 0";
    Grouped (n, stream)
  let concat left right = Concat (left, right)
  let flat_map f stream = Flat_map (stream, f)
  let merge left right = Merge (left, right)

  let flat_map_par ~max_concurrency f stream =
    if max_concurrency <= 0 then
      invalid_arg "Stream.flat_map_par: max_concurrency must be > 0";
    Flat_map_par (max_concurrency, stream, f)

  let from_eio_stream stream = From_eio_stream stream
  let from_queue queue = From_queue queue

  let from_file_map_error ?(chunk_size = default_file_chunk_size) ~on_error path =
    if chunk_size <= 0 then
      invalid_arg "Stream.from_file: chunk_size must be > 0";
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
    if max <= 0 then invalid_arg "Stream.Mailbox.to_batch_stream: max must be > 0";
    Stream.From_mailbox_batches (max, mailbox)
end

module Drain_counter = Drain_counter_internal

module Sink = struct
  type ('in_, 'out, 'err) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('out, 'err) Eta.Effect.t;
    done_ : 'out -> ('out, 'err) Eta.Effect.t;
  }

  let fold f init =
    {
      init = (fun () -> init);
      step = (fun acc value -> Eta.Effect.pure (f acc value));
      done_ = Eta.Effect.pure;
    }

  let fold_effect f init =
    { init = (fun () -> init); step = f; done_ = Eta.Effect.pure }

  let collect_to_list =
    {
      init = (fun () -> []);
      step = (fun acc value -> Eta.Effect.pure (value :: acc));
      done_ = (fun acc -> Eta.Effect.pure (List.rev acc));
    }

  let count =
    {
      init = (fun () -> 0);
      step = (fun acc _ -> Eta.Effect.pure (acc + 1));
      done_ = Eta.Effect.pure;
    }

  let drain =
    {
      init = (fun () -> ());
      step = (fun () _ -> Eta.Effect.unit);
      done_ = Eta.Effect.pure;
    }
end

type ('acc, 'a, 'err) folder = {
  emit : 'acc -> 'a -> ('acc * bool, 'err) Eta.Effect.t;
}

type 'a queue_event = Item of 'a | Done
type 'a outer_event = Outer_item of 'a | Outer_done


let file_error_kind_of_exn = function
  | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> `Already_exists
  | Eio.Io (Eio.Fs.E Eio.Fs.File_too_large, _) -> `File_too_large
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> `Not_found
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_native _), _) -> `Not_native
  | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) -> `Permission_denied
  | Eio.Io _ -> `Io
  | _ -> `Unexpected

let make_file_error ~operation ~path cause =
  {
    Stream.operation;
    path;
    kind = file_error_kind_of_exn cause;
    message = Format.asprintf "%a" Eio.Exn.pp cause;
    cause;
  }

let rec fold_values :
    type err acc a.
    a list ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
 fun values acc folder ->
  match values with
  | [] -> Eta.Effect.pure (acc, true)
  | value :: rest ->
      Eta.Effect.bind
        (fun (acc, keep_going) ->
          if keep_going then fold_values rest acc folder
          else Eta.Effect.pure (acc, false))
        (folder.emit acc value)

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
  | Map (inner, f) ->
      fold_stream inner acc { emit = (fun acc value -> folder.emit acc (f value)) }
  | Map_effect (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              Eta.Effect.bind (fun mapped -> folder.emit acc mapped) (f value));
        }
  | Filter (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if f value then folder.emit acc value
              else Eta.Effect.pure (acc, true));
        }
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
        { emit = (fun acc value -> fold_stream (f value) acc folder) }
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
          (Eta.Effect.named "Stream.from_eio_stream.take" (Eta.Effect.sync (fun () ->
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
          (Eta.Effect.named "Stream.Mailbox_internal.take" (Eta.Effect.sync (fun () ->
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
          (Eta.Effect.named "Stream.Mailbox_internal.take_batch" (Eta.Effect.sync (fun () ->
               Mailbox_internal.take_batch mailbox max)))
      in
      loop acc
  | From_file { chunk_size; path; path_label; on_error } ->
      let queue = Eio.Stream.create file_queue_capacity in
      let done_promise, done_resolver = Eio.Promise.create () in
      let stopped = Atomic.make false in
      let producer =
        Eta.Effect.bind
          (function
            | Ok () -> Eta.Effect.unit
            | Error error -> Eta.Effect.fail (on_error error))
          (Eta.Effect.named "Stream.from_file.read" (Eta.Effect.sync (fun () ->
               let finish () =
                 ignore (Eio.Promise.try_resolve done_resolver ())
               in
               Fun.protect ~finally:finish (fun () ->
                   let operation = ref `Open in
                   try
                     Eio.Switch.run ~name:"Stream.from_file" @@ fun sw ->
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
                                 Cstruct.to_bytes
                                   (Cstruct.sub buffer 0 bytes_read)
                               in
                               Eio.Stream.add queue chunk;
                               read_loop ())
                         | exception End_of_file -> operation := `Close
                     in
                     read_loop ();
                     Ok ()
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | exn ->
                       Error
                         (make_file_error ~operation:!operation
                            ~path:path_label exn)))))
      in
      let next_event () =
        match Eio.Stream.take_nonblocking queue with
        | Some chunk -> Item chunk
        | None when Eio.Promise.is_resolved done_promise -> Done
        | None ->
            Eio.Fiber.first
              (fun () -> Item (Eio.Stream.take queue))
              (fun () ->
                Eio.Promise.await done_promise;
                match Eio.Stream.take_nonblocking queue with
                | Some chunk -> Item chunk
                | None -> Done)
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
                  lift
                    (Eta.Effect.named "Stream.from_file.take" (Eta.Effect.sync (fun () ->
                         next_event ())))
                in
                match event with
                | Done ->
                    let* () = await child in
                    pure (acc, true)
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
  | Named (name, inner) -> Eta.Effect.named name (fold_stream inner acc folder)
  | Fn (file, line, col_start, col_end, name, inner) ->
      Eta.Effect.fn (file, line, col_start, col_end) name
        (fold_stream inner acc folder)

and fold_merge :
    type err acc a.
    (a, err) Stream.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Eta.Effect.t =
 fun left right acc folder ->
  let queue = Eio.Stream.create 1024 in
  let stopped = Atomic.make false in
  let producer stream =
    Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
      ~release:(fun () ->
        Eta.Effect.named "Stream.merge.done" (Eta.Effect.sync (fun () ->
            if not (Atomic.get stopped) then Eio.Stream.add queue Done)))
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.map ignore
             (fold_stream stream ()
                {
                  emit =
                    (fun () value ->
                      if Atomic.get stopped then Eta.Effect.pure ((), false)
                      else
                        Eta.Effect.map
                          (fun () -> ((), true))
                          (Eta.Effect.named "Stream.merge.emit" (Eta.Effect.sync (fun () ->
                               Eio.Stream.add queue (Item value)))));
                }))
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
                lift
                  (Eta.Effect.named "Stream.merge.take" (Eta.Effect.sync (fun () ->
                       Eio.Stream.take queue)))
              in
              match event with
              | Done -> consume (remaining - 1) acc
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
  let outer_queue = Eio.Stream.create max_concurrency in
  let output_queue = Eio.Stream.create 1024 in
  let stopped = Atomic.make false in
  let outer_producer =
    Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
      ~release:(fun () ->
        Eta.Effect.named "Stream.flat_map_par.outer_done" (Eta.Effect.sync (fun () ->
            if not (Atomic.get stopped) then
              Eio.Stream.add outer_queue Outer_done)))
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.map ignore
             (fold_stream inner ()
                {
                  emit =
                    (fun () value ->
                      if Atomic.get stopped then Eta.Effect.pure ((), false)
                      else
                        Eta.Effect.map
                          (fun () -> ((), true))
                          (Eta.Effect.named "Stream.flat_map_par.outer_emit" (Eta.Effect.sync (fun () ->
                               Eio.Stream.add outer_queue (Outer_item value)))));
                }))
  in
  let worker =
    Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
      ~release:(fun () ->
        Eta.Effect.named "Stream.flat_map_par.worker_done" (Eta.Effect.sync (fun () ->
            if not (Atomic.get stopped) then Eio.Stream.add output_queue Done)))
    |> Eta.Effect.bind (fun () ->
           let rec loop () =
             Eta.Effect.bind
               (function
                 | Outer_done ->
                     Eta.Effect.named "Stream.flat_map_par.rebroadcast_done" (Eta.Effect.sync (fun () -> Eio.Stream.add outer_queue Outer_done))
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
                                      (Eta.Effect.named "Stream.flat_map_par.inner_emit" (Eta.Effect.sync (fun () ->
                                           Eio.Stream.add output_queue
                                             (Item item)))));
                             })))
               (Eta.Effect.named "Stream.flat_map_par.outer_take" (Eta.Effect.sync (fun () ->
                    Eio.Stream.take outer_queue)))
           in
           loop ())
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
          let cancel_everything () =
            let () = Atomic.set stopped true in
            let* () = cancel outer_child in
            let* () =
              lift
                (Eta.Effect.named "Stream.flat_map_par.wake_workers" (Eta.Effect.sync (fun () ->
                     let rec drain_outer () =
                       match Eio.Stream.take_nonblocking outer_queue with
                       | None -> ()
                       | Some _ -> drain_outer ()
                     in
                     drain_outer ();
                     for _ = 1 to max_concurrency do
                       Eio.Stream.add outer_queue Outer_done
                     done)))
            in
            cancel_all workers
          in
          let await_everything () =
            let* () = await outer_child in
            await_all workers
          in
          let rec consume remaining_workers acc =
            if remaining_workers = 0 then
              let* () = await_everything () in
              pure (acc, true)
            else
              let* event =
                lift
                  (Eta.Effect.named "Stream.flat_map_par.take" (Eta.Effect.sync (fun () ->
                       Eio.Stream.take output_queue)))
              in
              match event with
              | Done -> consume (remaining_workers - 1) acc
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

let run stream sink =
  Eta.Effect.bind
    (fun (acc, _) -> sink.Sink.done_ acc)
    (fold_stream stream (sink.Sink.init ())
       {
         emit =
           (fun acc value ->
             Eta.Effect.map (fun acc -> (acc, true)) (sink.Sink.step acc value));
       })

let run_collect stream = run stream Sink.collect_to_list
let run_drain stream = run stream Sink.drain
