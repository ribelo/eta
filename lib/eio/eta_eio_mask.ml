(** Cancellation-mask restoration for the Eio backend.

    This is Eta's single implementation-file dependency on the hidden
    [Eio__core__Switch] and [Eio__core__Cancel] modules. [run_in] moves the
    current fiber into the mask-entry switch context without forking. A scoped
    relay forwards cancellation of the entry-time current context to that
    switch. Eio is pinned by this repository; an upgrade must revalidate this
    module against [Switch.run_in], [Switch.cancel], and [Cancel.cancel]. *)

type 'a outcome =
  | Returned of 'a
  | Raised of exn * Printexc.raw_backtrace

let capture f =
  match f () with
  | value -> Returned value
  | exception exn -> Raised (exn, Printexc.get_raw_backtrace ())

let unwrap = function
  | Returned value -> value
  | Raised (exn, bt) -> Printexc.raise_with_backtrace exn bt

let with_entry_cancel_relay restore_switch f =
  Eio.Switch.run ~name:"eta.interruptible.restore-relay" @@ fun relay_switch ->
  let active = ref true in
  Eio.Fiber.fork_daemon ~sw:relay_switch (fun () ->
      try Eio.Fiber.await_cancel () with
      | Eio.Cancel.Cancelled reason ->
        if !active then
          Eio__core__Cancel.cancel restore_switch.Eio__core__Switch.cancel
            reason;
        `Stop_daemon);
  Fun.protect ~finally:(fun () -> active := false) (fun () -> f relay_switch)

let restore switch f =
  let outcome = ref None in
  let run () =
    outcome :=
      Some
        (capture (fun () ->
             let value = f () in
             (* Same-domain Eio cancellation cannot race the move back after this
                check without another suspension point. *)
             Eio.Fiber.check ();
             value))
  in
  (match
     with_entry_cancel_relay switch (fun relay_switch ->
         Eio__core__Switch.run_in switch run;
         match !outcome with
         | Some (Returned _) -> Eio.Switch.check relay_switch
         | Some (Raised _) | None -> ())
   with
  | () -> ()
  | exception exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ()));
  match !outcome with
  | Some outcome -> unwrap outcome
  | None -> invalid_arg "Eta_eio_mask.restore: callback returned no outcome"

let with_cancel_mask body =
  Eio__core__Switch.run @@ fun restore_switch ->
  Eio.Cancel.protect @@ fun () ->
  body
    {
      Eta.Runtime_contract.restore =
        (fun (type a) (f : unit -> a) -> restore restore_switch f);
    }
