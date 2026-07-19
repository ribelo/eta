(* Baseline: today's always-open Syntax shape (pre-split call site style).
   Independent concurrent loads under a background lifecycle — no product
   module open. Reviewers should not be told whether and* forks. *)

open Eta

type error = [ `Missing_user of string ]

let load_user id =
  Effect.sync_result (fun () ->
      if String.equal id "" then Error (`Missing_user id)
      else Ok ("user:" ^ id))

let wait_started started =
  Effect.sync (fun () ->
      let rec loop attempts =
        if !started then ()
        else if attempts = 0 then failwith "background did not start"
        else (
          Eio.Fiber.yield ();
          loop (attempts - 1))
      in
      loop 1_000)

let background started stopped =
  let open Syntax in
  let* () =
    Effect.acquire_release
      ~acquire:(Effect.sync (fun () -> started := true))
      ~release:(fun () -> Effect.sync (fun () -> stopped := true))
  in
  Effect.yield

let program started stopped left_id right_id =
  let open Syntax in
  Effect.with_background ~name:"cache.refresh" (background started stopped)
    (fun () ->
      let* () = wait_started started in
      let* left = load_user left_id
      and* right = load_user right_id in
      Effect.pure (left, right))
