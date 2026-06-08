open Eta

module Http = Eta_http_stub

type outcome = Quiet of int * int | Looping of int * int

let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let drop n xs =
  let rec loop i xs =
    match (i, xs) with
    | 0, xs -> xs
    | _, [] -> []
    | i, _ :: rest -> loop (i - 1) rest
  in
  loop n xs

let simulate ~suppress_client_spans ~max_rounds =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  ignore (Runtime.run rt (Effect.named "app.operation" Effect.unit));
  let config =
    {
      Http.suppress_client_spans;
      pool_active = 1;
      pool_idle = 0;
    }
  in
  let exported = ref 0 in
  let rec loop round =
    let spans = Tracer.dump tracer in
    let total = List.length spans in
    if !exported >= total then Quiet (round, total)
    else if round >= max_rounds then Looping (round, total)
    else
      let new_spans = drop !exported spans in
      exported := total;
      List.iter
        (fun _span -> ignore (Runtime.run rt (Http.request ~config Otlp_export)))
        new_spans;
      loop (round + 1)
  in
  let outcome = loop 0 in
  Runtime.drain rt;
  outcome

let () =
  let unsuppressed = simulate ~suppress_client_spans:false ~max_rounds:6 in
  let suppressed = simulate ~suppress_client_spans:true ~max_rounds:6 in
  let unsuppressed_loops =
    match unsuppressed with Looping (_, total) when total > 1 -> true | _ -> false
  in
  let suppressed_quiets =
    match suppressed with Quiet (_, total) when total = 1 -> true | _ -> false
  in
  check "unsuppressed eta-http transport spans recurse" unsuppressed_loops;
  check "eta-otel transport filter reaches quiet state" suppressed_quiets;
  (match suppressed with
  | Quiet (rounds, total) ->
      Printf.printf "filtered recursion quiet after %d round(s), spans=%d\n%!"
        rounds total
  | Looping (rounds, total) ->
      Printf.printf "unexpected filtered loop after %d round(s), spans=%d\n%!"
        rounds total);
  Printf.printf "h_o1 recursion_test passed\n%!"
