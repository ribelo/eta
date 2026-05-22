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
    | From_effect : ('a, 'err) Effet.Effect.t -> ('a, 'err) t
    | Fail : 'err -> ('a, 'err) t
    | Map : ('a, 'err) t * ('a -> 'b) -> ('b, 'err) t
    | Map_effect :
        ('a, 'err) t * ('a -> ('b, 'err) Effet.Effect.t)
        -> ('b, 'err) t
    | Filter : ('a, 'err) t * ('a -> bool) -> ('a, 'err) t
    | Take : int * ('a, 'err) t -> ('a, 'err) t
    | Drop : int * ('a, 'err) t -> ('a, 'err) t
    | Scan : ('s -> 'a -> 's) * 's * ('a, 'err) t -> ('s, 'err) t
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
  let drop n stream = Drop (n, stream)
  let scan f init stream = Scan (f, init, stream)
  let concat left right = Concat (left, right)
  let flat_map f stream = Flat_map (stream, f)
  let merge left right = Merge (left, right)

  let flat_map_par ~max_concurrency f stream =
    if max_concurrency <= 0 then
      invalid_arg "Stream.flat_map_par: max_concurrency must be > 0";
    Flat_map_par (max_concurrency, stream, f)

  let from_eio_stream stream = From_eio_stream stream
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

module Sink = struct
  type ('in_, 'out, 'err) t = {
    init : unit -> 'out;
    step : 'out -> 'in_ -> ('out, 'err) Effet.Effect.t;
    done_ : 'out -> ('out, 'err) Effet.Effect.t;
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

type ('acc, 'a, 'err) folder = {
  emit : 'acc -> 'a -> ('acc * bool, 'err) Effet.Effect.t;
}

type 'a queue_event = Item of 'a | Done
type 'a outer_event = Outer_item of 'a | Outer_done

let bind f eff = Effet.Effect.bind f eff
let map f eff = Effet.Effect.map f eff

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
    (acc * bool, err) Effet.Effect.t =
 fun values acc folder ->
  match values with
  | [] -> Effet.Effect.pure (acc, true)
  | value :: rest ->
      bind
        (fun (acc, keep_going) ->
          if keep_going then fold_values rest acc folder
          else Effet.Effect.pure (acc, false))
        (folder.emit acc value)

and fold_stream :
    type err acc a.
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Effet.Effect.t =
 fun stream acc folder ->
  match stream with
  | Stream.Empty -> Effet.Effect.pure (acc, true)
  | Chunk values -> fold_values values acc folder
  | From_effect eff -> bind (fun value -> folder.emit acc value) eff
  | Fail error -> Effet.Effect.fail error
  | Map (inner, f) ->
      fold_stream inner acc { emit = (fun acc value -> folder.emit acc (f value)) }
  | Map_effect (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              bind (fun mapped -> folder.emit acc mapped) (f value));
        }
  | Filter (inner, f) ->
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if f value then folder.emit acc value
              else Effet.Effect.pure (acc, true));
        }
  | Take (n, inner) ->
      if n <= 0 then Effet.Effect.pure (acc, false)
      else
        let remaining = ref n in
        fold_stream inner acc
          {
            emit =
              (fun acc value ->
                if !remaining <= 0 then Effet.Effect.pure (acc, false)
                else (
                  decr remaining;
                  map
                    (fun (acc, keep_going) ->
                      (acc, keep_going && !remaining > 0))
                    (folder.emit acc value)));
          }
  | Drop (n, inner) ->
      let remaining = ref (max 0 n) in
      fold_stream inner acc
        {
          emit =
            (fun acc value ->
              if !remaining > 0 then (
                decr remaining;
                Effet.Effect.pure (acc, true))
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
  | Concat (left, right) ->
      bind
        (fun (acc, keep_going) ->
          if keep_going then fold_stream right acc folder
          else Effet.Effect.pure (acc, false))
        (fold_stream left acc folder)
  | Flat_map (inner, f) ->
      fold_stream inner acc
        { emit = (fun acc value -> fold_stream (f value) acc folder) }
  | Merge (left, right) -> fold_merge left right acc folder
  | Flat_map_par (max_concurrency, inner, f) ->
      fold_flat_map_par ~max_concurrency inner f acc folder
  | From_eio_stream stream ->
      let rec loop acc =
        bind
          (fun value ->
            bind
              (fun (acc, keep_going) ->
                if keep_going then loop acc else Effet.Effect.pure (acc, false))
              (folder.emit acc value))
          (Effet.Effect.thunk "Stream.from_eio_stream.take" (fun () ->
               Eio.Stream.take stream))
      in
      loop acc
  | From_file { chunk_size; path; path_label; on_error } ->
      let queue = Eio.Stream.create file_queue_capacity in
      let done_promise, done_resolver = Eio.Promise.create () in
      let stopped = Atomic.make false in
      let producer =
        bind
          (function
            | Ok () -> Effet.Effect.unit
            | Error error -> Effet.Effect.fail (on_error error))
          (Effet.Effect.thunk "Stream.from_file.read" (fun () ->
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
                            ~path:path_label exn))))
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
      Effet.Supervisor.scoped
        {
          run =
            (fun (type s) sup ->
              let open Effet.Supervisor.Scope in
              let* (child : (s, err, unit) Effet.Supervisor.child) =
                start sup (lift producer)
              in
              let rec consume acc =
                let* event =
                  lift
                    (Effet.Effect.thunk "Stream.from_file.take" (fun () ->
                         next_event ()))
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
  | Named (name, inner) -> Effet.Effect.named name (fold_stream inner acc folder)
  | Fn (file, line, col_start, col_end, name, inner) ->
      Effet.Effect.fn (file, line, col_start, col_end) name
        (fold_stream inner acc folder)

and fold_merge :
    type err acc a.
    (a, err) Stream.t ->
    (a, err) Stream.t ->
    acc ->
    (acc, a, err) folder ->
    (acc * bool, err) Effet.Effect.t =
 fun left right acc folder ->
  let queue = Eio.Stream.create 1024 in
  let stopped = Atomic.make false in
  let producer stream =
    Effet.Effect.acquire_release ~acquire:Effet.Effect.unit
      ~release:(fun () ->
        Effet.Effect.thunk "Stream.merge.done" (fun () ->
            if not (Atomic.get stopped) then Eio.Stream.add queue Done))
    |> bind (fun () ->
           map ignore
             (fold_stream stream ()
                {
                  emit =
                    (fun () value ->
                      if Atomic.get stopped then Effet.Effect.pure ((), false)
                      else
                        map
                          (fun () -> ((), true))
                          (Effet.Effect.thunk "Stream.merge.emit" (fun () ->
                               Eio.Stream.add queue (Item value))));
                }))
  in
  Effet.Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Effet.Supervisor.Scope in
          let* (left_child : (s, err, unit) Effet.Supervisor.child) =
            start sup (lift (producer left))
          in
          let* (right_child : (s, err, unit) Effet.Supervisor.child) =
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
                  (Effet.Effect.thunk "Stream.merge.take" (fun () ->
                       Eio.Stream.take queue))
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
    (acc * bool, err) Effet.Effect.t =
 fun ~max_concurrency inner f acc folder ->
  let outer_queue = Eio.Stream.create max_concurrency in
  let output_queue = Eio.Stream.create 1024 in
  let stopped = Atomic.make false in
  let outer_producer =
    Effet.Effect.acquire_release ~acquire:Effet.Effect.unit
      ~release:(fun () ->
        Effet.Effect.thunk "Stream.flat_map_par.outer_done" (fun () ->
            if not (Atomic.get stopped) then
              Eio.Stream.add outer_queue Outer_done))
    |> bind (fun () ->
           map ignore
             (fold_stream inner ()
                {
                  emit =
                    (fun () value ->
                      if Atomic.get stopped then Effet.Effect.pure ((), false)
                      else
                        map
                          (fun () -> ((), true))
                          (Effet.Effect.thunk "Stream.flat_map_par.outer_emit"
                             (fun () ->
                               Eio.Stream.add outer_queue (Outer_item value))));
                }))
  in
  let worker =
    Effet.Effect.acquire_release ~acquire:Effet.Effect.unit
      ~release:(fun () ->
        Effet.Effect.thunk "Stream.flat_map_par.worker_done" (fun () ->
            if not (Atomic.get stopped) then Eio.Stream.add output_queue Done))
    |> bind (fun () ->
           let rec loop () =
             bind
               (function
                 | Outer_done ->
                     Effet.Effect.thunk "Stream.flat_map_par.rebroadcast_done"
                       (fun () -> Eio.Stream.add outer_queue Outer_done)
                 | Outer_item value ->
                     bind
                       (fun _ -> loop ())
                       (map ignore
                          (fold_stream (f value) ()
                             {
                               emit =
                                 (fun () item ->
                                  if Atomic.get stopped then
                                    Effet.Effect.pure ((), false)
                                  else
                                    map
                                      (fun () -> ((), true))
                                      (Effet.Effect.thunk
                                         "Stream.flat_map_par.inner_emit"
                                         (fun () ->
                                           Eio.Stream.add output_queue
                                             (Item item))));
                             })))
               (Effet.Effect.thunk "Stream.flat_map_par.outer_take" (fun () ->
                    Eio.Stream.take outer_queue))
           in
           loop ())
  in
  Effet.Supervisor.scoped
    {
      run =
        (fun (type s) sup ->
          let open Effet.Supervisor.Scope in
          let* (outer_child : (s, err, unit) Effet.Supervisor.child) =
            start sup (lift outer_producer)
          in
          let rec start_workers n acc =
            if n <= 0 then pure (List.rev acc)
            else
              let* (child : (s, err, unit) Effet.Supervisor.child) =
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
                (Effet.Effect.thunk "Stream.flat_map_par.wake_workers" (fun () ->
                     let rec drain_outer () =
                       match Eio.Stream.take_nonblocking outer_queue with
                       | None -> ()
                       | Some _ -> drain_outer ()
                     in
                     drain_outer ();
                     for _ = 1 to max_concurrency do
                       Eio.Stream.add outer_queue Outer_done
                     done))
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
                  (Effet.Effect.thunk "Stream.flat_map_par.take" (fun () ->
                       Eio.Stream.take output_queue))
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
    type err a. (a, err) Stream.t -> (a list, err) Effet.Effect.t =
 fun stream ->
  map
    (fun (values, _) -> List.rev values)
    (fold_stream stream []
       { emit = (fun acc value -> Effet.Effect.pure (value :: acc, true)) })

let run stream sink =
  bind
    (fun (acc, _) -> sink.Sink.done_ acc)
    (fold_stream stream (sink.Sink.init ())
       {
         emit =
           (fun acc value ->
             map (fun acc -> (acc, true)) (sink.Sink.step acc value));
       })

let run_collect stream = run stream Sink.collect_to_list
let run_drain stream = run stream Sink.drain
