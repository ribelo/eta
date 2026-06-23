module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

module Int_cache = Eta_cache.Make (struct
  type t = int

  let equal = Int.equal
  let hash = Hashtbl.hash
end)

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let fail message = failwith message
let pp_err fmt _ = Format.pp_print_string fmt "<cache-error>"

let finish done_ f value =
  try
    f value;
    done_ ()
  with exn ->
    set_exit_code 1;
    log ("eta_cache_jsoo failed: " ^ Printexc.to_string exn)

let run eff ~on_result =
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime eff ~on_result

let expect_ok = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      fail
        (Format.asprintf "expected Ok, got %a" (Eta.Cause.pp pp_err) cause)

let test_single_flight_refresh_invalidate done_ =
  let calls = ref 0 in
  let lookup key =
    Eta.Effect.sync (fun () -> incr calls)
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.delay (Eta.Duration.ms 1)
             (Eta.Effect.pure (key * 10 + !calls)))
  in
  let ttl _exit _key = Eta.Duration.seconds 60 in
  let program =
    Int_cache.make ~capacity:2 ~lookup ~time_to_live:ttl
    |> Eta.Effect.bind (fun cache ->
           Eta.Effect.all [ Int_cache.get cache 1; Int_cache.get cache 1 ]
           |> Eta.Effect.bind (fun values ->
                  Int_cache.refresh cache 1
                  |> Eta.Effect.bind (fun refreshed ->
                         Int_cache.invalidate cache 1
                         |> Eta.Effect.bind (fun () ->
                                Int_cache.get_if_present cache 1
                                |> Eta.Effect.bind (fun present ->
                                       Int_cache.stats cache
                                       |> Eta.Effect.map (fun stats ->
                                              ( values,
                                                refreshed,
                                                present,
                                                !calls,
                                                stats.Int_cache.current_size )))))))
  in
  run program
    ~on_result:
      (finish done_ (fun result ->
           let values, refreshed, present, calls, current_size =
             expect_ok result
           in
           if values <> [ 11; 11 ] then fail "single-flight values mismatch";
           if refreshed <> 12 then fail "refresh value mismatch";
           if Option.is_some present then fail "invalidate did not remove value";
           if calls <> 2 then fail "lookup count mismatch";
           if current_size <> 0 then fail "current_size mismatch"))

let tests = [ ("single-flight/refresh/invalidate", test_single_flight_refresh_invalidate) ]

let rec run_tests = function
  | [] -> log "eta_cache_jsoo ok"
  | (name, test) :: rest ->
      test (fun () ->
          log ("ok: " ^ name);
          run_tests rest)

let () =
  try run_tests tests
  with exn ->
    set_exit_code 1;
    log ("eta_cache_jsoo failed: " ^ Printexc.to_string exn)
