let cause_of_promise_error error =
  Cause.die (Js.Exn.anyToExnInternal (Obj.magic error))

let await_promise ?name ?on_cancel make_promise =
  Effect.Expert.async_leaf ?name (fun _context ~resume ~on_cancel:register_cancel ->
      let settled = ref false in
      let cancel_called = ref false in
      let finish exit =
        if not !settled then begin
          settled := true;
          resume exit
        end
      in
      let call_cancel () =
        if not !cancel_called then begin
          cancel_called := true;
          match on_cancel with
          | None -> ()
          | Some cancel -> cancel ()
        end
      in
      register_cancel (fun () ->
          if not !settled then begin
            settled := true;
            call_cancel ()
          end);
      try
        let promise = make_promise () in
        ignore
          (Js.Promise.catch
             (fun error ->
               finish (Exit.error (cause_of_promise_error error));
               Js.Promise.resolve ())
             (Js.Promise.then_
                (fun value ->
                  finish (Exit.ok value);
                  Js.Promise.resolve ())
                promise))
      with exn -> finish (Exit.error (Cause.die exn)))

let await_abortable ?name make_promise =
  Effect.Expert.async_leaf ?name (fun _context ~resume ~on_cancel ->
      let controller = Js_interop.make_abort_controller () in
      let settled = ref false in
      let aborted = ref false in
      let finish exit =
        if not !settled then begin
          settled := true;
          resume exit
        end
      in
      let abort () =
        if not !aborted then begin
          aborted := true;
          Js_interop.abort controller
        end
      in
      on_cancel (fun () ->
          if not !settled then begin
            settled := true;
            abort ()
          end);
      try
        let promise = make_promise (Js_interop.signal controller) in
        ignore
          (Js.Promise.catch
             (fun error ->
               finish (Exit.error (cause_of_promise_error error));
               Js.Promise.resolve ())
             (Js.Promise.then_
                (fun result ->
                  (match result with
                  | Ok value -> finish (Exit.ok value)
                  | Error err -> finish (Exit.error (Cause.fail err)));
                  Js.Promise.resolve ())
                promise))
      with exn -> finish (Exit.error (Cause.die exn)))
