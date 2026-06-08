open Eta
open Common

module type CANDIDATE = sig
  type t

  val label : string
  val create : ?config:pool_config -> factory -> (t, error) Effect.t

  val with_connection :
    t -> (connection -> (unit, error) Effect.t) -> (unit, error) Effect.t

  val shutdown : ?deadline:Duration.t -> t -> (unit, error) Effect.t
end

module Branch_a : CANDIDATE = struct
  type t = Branch_a_internal_pool.t

  let label = "branch_a_internal_pool"
  let create = Branch_a_internal_pool.create
  let with_connection = Branch_a_internal_pool.with_connection
  let shutdown = Branch_a_internal_pool.shutdown
end

module Branch_b : CANDIDATE = struct
  type t = connection Branch_b_eta_pool.t

  let label = "branch_b_eta_pool"
  let create = Branch_b_eta_pool.create_for_fake
  let with_connection = Branch_b_eta_pool.with_resource
  let shutdown = Branch_b_eta_pool.shutdown
end

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected Eta failure: %a\n%!"
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause;
      exit 1

let churn count (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 8;
      max_idle = 8;
      idle_lifetime = Some (Duration.seconds 10);
      max_lifetime = Some (Duration.seconds 60);
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         list_init count (fun _ ->
             P.with_connection pool (fun conn -> use_connection conn))
         |> Effect.concat
         |> Effect.bind (fun () -> P.shutdown ~deadline:(Duration.ms 100) pool))

let measure count candidate =
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  run_effect (churn count candidate);
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let after = Gc.stat () in
  let label =
    let module P = (val candidate : CANDIDATE) in
    P.label
  in
  Printf.printf
    "%s allocation_probe count=%d wall_ms=%d minor_words=%.0f promoted_words=%.0f major_words=%.0f minor_collections=%d major_collections=%d\n%!"
    label count elapsed_ms
    (after.minor_words -. before.minor_words)
    (after.promoted_words -. before.promoted_words)
    (after.major_words -. before.major_words)
    (after.minor_collections - before.minor_collections)
    (after.major_collections - before.major_collections)

let () =
  let count = 1_000 in
  measure count (module Branch_a);
  measure count (module Branch_b)
