(** Cancellation-mask restoration for the Eio backend.

    This is Eta's single dependency on the hidden [Eio__core__Switch] module.
    [run_in] moves the current fiber into the mask-entry switch context without
    forking. Eio is pinned by this repository; an Eio upgrade must revalidate
    this module against [Switch.run_in] and [Cancel.move_fiber_to]. *)

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
  (match Eio__core__Switch.run_in switch run with
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
