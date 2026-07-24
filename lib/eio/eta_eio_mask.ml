(** Cancellation-mask restoration for the Eio backend.

    This is Eta's single implementation-file dependency on the hidden
    [Eio__core__Switch] and [Eio__core__Cancel] modules. [run_in] moves the
    current fiber into the mask-entry switch context without forking. A
    synthetic fiber context forwards cancellation of the entry-time current
    context synchronously to that switch. Eio is pinned by this repository; an
    upgrade must revalidate this module against [Switch.run_in], [Switch.cancel],
    [Cancel.cancel], and [Cancel.Fiber_context]. *)

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

let with_entry_cancel_observer restore_switch f =
  Eio.Fiber.check ();
  let current = Effect.perform Eio__core__Cancel.Get_context in
  let observer =
    Eio__core__Cancel.Fiber_context.make
      ~cc:(Eio__core__Cancel.Fiber_context.cancellation_context current)
      ~vars:(Eio__core__Cancel.Fiber_context.get_vars ())
  in
  Eio__core__Cancel.Fiber_context.set_cancel_fn observer (fun exn ->
      match exn with
      | Eio.Cancel.Cancelled reason ->
        Eio__core__Cancel.cancel restore_switch.Eio__core__Switch.cancel reason
      | _ -> assert false);
  Fun.protect
    ~finally:(fun () -> Eio__core__Cancel.Fiber_context.destroy observer)
    f

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
     with_entry_cancel_observer switch (fun () ->
         Eio__core__Switch.run_in switch run)
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
