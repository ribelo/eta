exception Probe_failure of string

let require condition message =
  if not condition then raise (Probe_failure message)

let reason_is expected = function
  | Eio.Cancel.Cancelled actual -> actual == expected
  | _ -> false

let parent_cancel_during_sub ~sw =
  let parent_reason = Failure "parent cancellation" in
  let blocked_wait_returned = ref false in
  let protect_returned = ref false in
  let delivered_after_protect = ref false in
  Eio.Cancel.sub @@ fun parent ->
  Eio.Cancel.protect (fun () ->
      Eio.Cancel.sub @@ fun _child ->
      let release, release_resolver = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Fiber.yield ();
          Eio.Promise.resolve release_resolver ());
      Eio.Cancel.cancel parent parent_reason;
      Eio.Promise.await release;
      blocked_wait_returned := true);
  protect_returned := true;
  (try Eio.Fiber.check () with
  | exn when reason_is parent_reason exn -> delivered_after_protect := true);
  require !blocked_wait_returned
    "parent cancellation reached the sub-context inside protect";
  require !protect_returned "parent cancellation escaped protect";
  require !delivered_after_protect
    "pending parent cancellation was not seen by the next check";
  Printf.printf
    "native parent->protect->sub: blocked_wait=returned protect=returned \
     next_check=cancelled\n%!"

let explicit_sub_cancel_escapes_protect () =
  let child_reason = Failure "explicit child cancellation" in
  let escaped = ref false in
  Eio.Cancel.sub @@ fun _parent ->
  (try
     Eio.Cancel.protect (fun () ->
         Eio.Cancel.sub @@ fun child ->
         Eio.Cancel.cancel child child_reason;
         Eio.Fiber.yield ())
   with exn when reason_is child_reason exn -> escaped := true);
  require !escaped
    "explicit cancellation of the sub-context did not escape protect";
  Printf.printf "native explicit-sub-cancel: escaped-protect=yes\n%!"

let nested_protect_parent_cancel () =
  let parent_reason = Failure "nested parent cancellation" in
  let inner_returned = ref false in
  let outer_returned = ref false in
  let delivered_after_outer = ref false in
  Eio.Cancel.sub @@ fun parent ->
  Eio.Cancel.protect (fun () ->
      Eio.Cancel.protect (fun () ->
          Eio.Cancel.cancel parent parent_reason;
          Eio.Fiber.yield ();
          inner_returned := true);
      outer_returned := true);
  (try Eio.Fiber.check () with
  | exn when reason_is parent_reason exn -> delivered_after_outer := true);
  require !inner_returned "inner protect did not return";
  require !outer_returned "outer protect did not return";
  require !delivered_after_outer
    "nested protect lost pending parent cancellation";
  Printf.printf
    "native nested-protect: inner=returned outer=returned \
     next_check=cancelled\n%!"

let () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  parent_cancel_during_sub ~sw;
  explicit_sub_cancel_escapes_protect ();
  nested_protect_parent_cancel ();
  Printf.printf "native probe: PASS\n%!"
