open Eta

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected error: %a@."
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause;
      exit 1

let gc_words f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  f ();
  let after = Gc.quick_stat () in
  ( after.minor_words -. before.minor_words,
    after.promoted_words -. before.promoted_words,
    after.major_words -. before.major_words )

let probe_try rt =
  let ch = Channel.create ~capacity:1 () in
  let minor, promoted, major =
    gc_words @@ fun () ->
    for i = 1 to 10_000 do
      (match run_ok rt (Channel.try_send ch i) with
      | `Sent -> ()
      | _ -> failwith "try_send");
      match run_ok rt (Channel.try_recv ch) with
      | `Item _ -> ()
      | _ -> failwith "try_recv"
    done
  in
  let stats = Channel.stats ch in
  Printf.printf
    "try_send_recv iterations=10000 minor_words=%.0f promoted_words=%.0f major_words=%.0f sent=%d received=%d depth=%d\n"
    minor promoted major stats.sent stats.received stats.depth

let probe_blocking rt sw =
  let ch = Channel.create ~capacity:16 () in
  let producers = 4 in
  let per_producer = 1_000 in
  let total = producers * per_producer in
  let minor, promoted, major =
    gc_words @@ fun () ->
    for p = 0 to producers - 1 do
      Eio.Fiber.fork ~sw (fun () ->
          for i = 1 to per_producer do
            run_ok rt (Channel.send ch ((p * per_producer) + i))
          done)
    done;
    for _ = 1 to total do
      ignore (run_ok rt (Channel.recv ch) : int)
    done
  in
  let stats = Channel.stats ch in
  Printf.printf
    "blocking_contention producers=%d total=%d minor_words=%.0f promoted_words=%.0f major_words=%.0f sent=%d received=%d depth=%d waiting_senders=%d waiting_receivers=%d cancelled_senders=%d\n"
    producers total minor promoted major stats.sent stats.received stats.depth
    stats.waiting_senders stats.waiting_receivers stats.cancelled_senders

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  probe_try rt;
  probe_blocking rt sw
