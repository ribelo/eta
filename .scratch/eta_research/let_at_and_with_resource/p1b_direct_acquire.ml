open Eta

module Effect_with_resource = struct
  let with_resource ~acquire ~release body =
    let open Syntax in
    let* resource = Effect.acquire_release ~acquire ~release in
    body resource
end

module Semaphore_site = struct
  type sem = { mutable permits : int }

  let acquire sem n =
    Effect.sync (fun () ->
        sem.permits <- sem.permits - n)

  let release sem n =
    Effect.sync (fun () ->
        sem.permits <- sem.permits + n)

  let h_a sem n f =
    Effect.scoped
      (Effect.acquire_release ~acquire:(acquire sem n)
         ~release:(fun () -> release sem n)
      |> Effect.bind (fun () -> f ()))

  let h_b sem n f =
    Effect.scoped
      (Effect_with_resource.with_resource ~acquire:(acquire sem n)
         ~release:(fun () -> release sem n)
         (fun () -> f ()))

  let h_c sem n f =
    let with_permits body =
      Effect.scoped
        (Effect.acquire_release ~acquire:(acquire sem n)
           ~release:(fun () -> release sem n)
        |> Effect.bind (fun () -> body ()))
    in
    let ( let@ ) f k = f k in
    let@ () = with_permits in
    f ()

  let h_d sem n f =
    let ( let@ ) f k = f k in
    Effect.scoped
      (let@ () =
         Effect_with_resource.with_resource ~acquire:(acquire sem n)
           ~release:(fun () -> release sem n)
       in
       f ())
end

module Pubsub_site = struct
  type sub = { id : int }
  type hub = { mutable active : int }

  let add_subscription hub =
    Effect.sync (fun () ->
        hub.active <- hub.active + 1;
        { id = hub.active })

  let release_subscription hub _sub =
    Effect.sync (fun () ->
        hub.active <- hub.active - 1)

  let h_a hub f =
    Effect.scoped
      (Effect.acquire_release ~acquire:(add_subscription hub)
         ~release:(release_subscription hub)
      |> Effect.bind f)

  let h_b hub f =
    Effect.scoped
      (Effect_with_resource.with_resource ~acquire:(add_subscription hub)
         ~release:(release_subscription hub) f)

  let h_c hub f =
    let with_subscription body =
      Effect.scoped
        (Effect.acquire_release ~acquire:(add_subscription hub)
           ~release:(release_subscription hub)
        |> Effect.bind body)
    in
    let ( let@ ) f k = f k in
    let@ sub = with_subscription in
    f sub

  let h_d hub f =
    let ( let@ ) f k = f k in
    Effect.scoped
      (let@ sub =
         Effect_with_resource.with_resource ~acquire:(add_subscription hub)
           ~release:(release_subscription hub)
       in
       f sub)
end

module Body_source_site = struct
  type owned = { name : string }

  let discard owned = Effect.sync (fun () -> ignore owned.name)

  let h_a owned f =
    Effect.scoped
      (Effect.acquire_release ~acquire:(Effect.pure owned) ~release:discard
      |> Effect.bind (fun owned -> f (Some owned)))

  let h_b owned f =
    Effect.scoped
      (Effect_with_resource.with_resource ~acquire:(Effect.pure owned)
         ~release:discard
         (fun owned -> f (Some owned)))

  let h_c owned f =
    let with_owned body =
      Effect.scoped
        (Effect.acquire_release ~acquire:(Effect.pure owned) ~release:discard
        |> Effect.bind body)
    in
    let ( let@ ) f k = f k in
    let@ owned = with_owned in
    f (Some owned)

  let h_d owned f =
    let ( let@ ) f k = f k in
    Effect.scoped
      (let@ owned =
         Effect_with_resource.with_resource ~acquire:(Effect.pure owned)
           ~release:discard
       in
       f (Some owned))
end

module Mixed_consumer_site = struct
  type client = { endpoint : string }
  type owned_stream = { topic : string }
  type monitor = { device : string }

  let with_client endpoint body = body { endpoint }
  let with_monitor device body = body { device }
  let acquire_stream topic = Effect.pure { topic }
  let release_stream _stream = Effect.unit

  let run ~client ~stream ~monitor =
    Effect.pure (client.endpoint ^ ":" ^ stream.topic ^ ":" ^ monitor.device)

  let h_a () =
    with_client "pulse.local" @@ fun client ->
    Effect.scoped
      (Effect.acquire_release ~acquire:(acquire_stream "ptt")
         ~release:release_stream
      |> Effect.bind (fun stream ->
             with_monitor "kbd0" @@ fun monitor ->
             run ~client ~stream ~monitor))

  let h_b () =
    with_client "pulse.local" @@ fun client ->
    Effect.scoped
      (Effect_with_resource.with_resource ~acquire:(acquire_stream "ptt")
         ~release:release_stream
      @@ fun stream ->
      with_monitor "kbd0" @@ fun monitor ->
      run ~client ~stream ~monitor)

  let h_c () =
    let ( let@ ) f k = f k in
    let with_stream body =
      Effect.scoped
        (Effect.acquire_release ~acquire:(acquire_stream "ptt")
           ~release:release_stream
        |> Effect.bind body)
    in
    let@ client = with_client "pulse.local" in
    let@ stream = with_stream in
    let@ monitor = with_monitor "kbd0" in
    run ~client ~stream ~monitor

  let h_d () =
    let ( let@ ) f k = f k in
    let@ client = with_client "pulse.local" in
    Effect.scoped
      (let@ stream =
         Effect_with_resource.with_resource ~acquire:(acquire_stream "ptt")
           ~release:release_stream
       in
       let@ monitor = with_monitor "kbd0" in
       run ~client ~stream ~monitor)
end

type applicability = Body_bounded | Scope_end_required

let applicability_to_string = function
  | Body_bounded -> "body-bounded"
  | Scope_end_required -> "scope-end-required"

let snippets =
  [
    ( "semaphore.with_permits",
      Body_bounded,
      [
        ( "H-A",
          {|Effect.scoped
  (Effect.acquire_release
     ~acquire:(acquire sem n)
     ~release:(fun () -> release sem n)
  |> Effect.bind (fun () -> f ()))|} );
        ( "H-B",
          {|Effect.scoped
  (Effect.with_resource
     ~acquire:(acquire sem n)
     ~release:(fun () -> release sem n)
     (fun () -> f ()))|} );
        ( "H-C",
          {|let with_permits body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(acquire sem n)
       ~release:(fun () -> release sem n)
    |> Effect.bind (fun () -> body ()))
in
let@ () = with_permits in
f ()|} );
        ( "H-D",
          {|Effect.scoped
  (let@ () =
     Effect.with_resource
       ~acquire:(acquire sem n)
       ~release:(fun () -> release sem n)
   in
   f ())|} );
      ] );
    ( "pubsub.subscribe",
      Body_bounded,
      [
        ( "H-A",
          {|Effect.scoped
  (Effect.acquire_release
     ~acquire:(add_subscription t)
     ~release:(release_subscription t)
  |> Effect.bind f)|} );
        ( "H-B",
          {|Effect.scoped
  (Effect.with_resource
     ~acquire:(add_subscription t)
     ~release:(release_subscription t)
     f)|} );
        ( "H-C",
          {|let with_subscription body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(add_subscription t)
       ~release:(release_subscription t)
    |> Effect.bind body)
in
let@ sub = with_subscription in
f sub|} );
        ( "H-D",
          {|Effect.scoped
  (let@ sub =
     Effect.with_resource
       ~acquire:(add_subscription t)
       ~release:(release_subscription t)
   in
   f sub)|} );
      ] );
    ( "body_source.with_owned_stream",
      Body_bounded,
      [
        ( "H-A",
          {|Effect.scoped
  (Effect.acquire_release
     ~acquire:(Effect.pure owned)
     ~release:discard
  |> Effect.bind (fun owned -> f (Some owned)))|} );
        ( "H-B",
          {|Effect.scoped
  (Effect.with_resource
     ~acquire:(Effect.pure owned)
     ~release:discard
     (fun owned -> f (Some owned)))|} );
        ( "H-C",
          {|let with_owned body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(Effect.pure owned)
       ~release:discard
    |> Effect.bind body)
in
let@ owned = with_owned in
f (Some owned)|} );
        ( "H-D",
          {|Effect.scoped
  (let@ owned =
     Effect.with_resource
       ~acquire:(Effect.pure owned)
       ~release:discard
   in
   f (Some owned))|} );
      ] );
    ( "pool.with_acquire_guard",
      Scope_end_required,
      [
        ( "H-A",
          {|Effect.scoped
  (Effect.acquire_release
     ~acquire:Effect.unit
     ~release
  |> Effect.bind (fun () -> f ~disarm ~set_release))|} );
        ( "H-B",
          {|Effect.scoped
  (Effect.with_resource
     ~acquire:Effect.unit
     ~release
     (fun () -> f ~disarm ~set_release))|} );
        ( "H-C",
          {|let with_guard body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:Effect.unit
       ~release
    |> Effect.bind (fun () -> body ()))
in
let@ () = with_guard in
f ~disarm ~set_release|} );
        ( "H-D",
          {|Effect.scoped
  (let@ () =
     Effect.with_resource
       ~acquire:Effect.unit
       ~release
   in
   f ~disarm ~set_release)|} );
      ] );
    ( "mixed.consumer.with_and_direct",
      Body_bounded,
      [
        ( "H-A",
          {|with_client "pulse.local" @@ fun client ->
Effect.scoped
  (Effect.acquire_release
     ~acquire:(acquire_stream "ptt")
     ~release:release_stream
  |> Effect.bind (fun stream ->
       with_monitor "kbd0" @@ fun monitor ->
       run ~client ~stream ~monitor))|} );
        ( "H-B",
          {|with_client "pulse.local" @@ fun client ->
Effect.scoped
  (Effect.with_resource
     ~acquire:(acquire_stream "ptt")
     ~release:release_stream
  @@ fun stream ->
  with_monitor "kbd0" @@ fun monitor ->
  run ~client ~stream ~monitor)|} );
        ( "H-C",
          {|let with_stream body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(acquire_stream "ptt")
       ~release:release_stream
    |> Effect.bind body)
in
let@ client = with_client "pulse.local" in
let@ stream = with_stream in
let@ monitor = with_monitor "kbd0" in
run ~client ~stream ~monitor|} );
        ( "H-D",
          {|let@ client = with_client "pulse.local" in
Effect.scoped
  (let@ stream =
     Effect.with_resource
       ~acquire:(acquire_stream "ptt")
       ~release:release_stream
   in
   let@ monitor = with_monitor "kbd0" in
   run ~client ~stream ~monitor)|} );
      ] );
  ]

let non_blank_lines s =
  String.split_on_char '\n' s
  |> List.filter (fun line -> String.trim line <> "")
  |> List.length

let leading_spaces line =
  let rec loop i =
    if i < String.length line && line.[i] = ' ' then loop (i + 1) else i
  in
  loop 0

let average_indent s =
  let lines =
    String.split_on_char '\n' s
    |> List.filter (fun line -> String.trim line <> "")
  in
  let total = List.fold_left (fun acc line -> acc + leading_spaces line) 0 lines in
  float total /. float (List.length lines)

let () =
  List.iter
    (fun (site, applicability, variants) ->
      List.iter
        (fun (hypothesis, snippet) ->
          Printf.printf "%s %s applicability=%s lines=%d avg_indent=%.2f\n" site
            hypothesis (applicability_to_string applicability)
            (non_blank_lines snippet) (average_indent snippet))
        variants)
    snippets
