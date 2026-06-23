open Eta

(* eta_cache_fixture — single-flight protocol probe, CONTRACT-ROUTED.

   This version proves the recommendation's actual design: single-flight rides
   the dual-platform [Runtime_contract] promise ([create_promise]/
   [resolve_promise]/[await_promise]), NOT [Eio.Promise] directly. The contract
   is grabbed once via [Effect.Expert.contract] (the same recipe Pool uses to
   stash [shutdown_contract]) and stashed in the cache record. This is what
   makes the cache automatically dual-platform: eio implements the contract
   promise via Eio.Promise; jsoo implements it via its own cooperative promise.

   Run (native):
     nix develop -c dune exec --root .scratch \
       ./evidence/eta-cache-research/eta_cache_fixture/runtime_smoke.exe
   See ../recommendation.md Q6.

   Remaining limit: this is exercised on the NATIVE (eio) backend. The jsoo
   backend implements the identical contract promise surface (read directly in
   lib/jsoo/eta_jsoo.ml), so the protocol transfers; an end-to-end jsoo run is
   the deferred obligation (no jsoo-executable pattern exists in the tree). *)

(* A one-shot completion handle delivering an Exit, backed by the runtime
   contract promise. [done_] guards against a second resolve (the contract
   resolver would otherwise raise / be a no-op). *)
type ('a, 'e) pending = {
  promise : ('a, 'e) Exit.t Runtime_contract.promise;
  resolver : ('a, 'e) Exit.t Runtime_contract.resolver;
  mutable done_ : bool;
}

type ('k, 'a, 'e) lookup = {
  run : 'k -> ('a, 'e) Effect.t;
  mutable calls : int;
  mutable fail_next : bool;
}

type ('k, 'a, 'e) status =
  | Pending of ('a, 'e) pending
  | Complete of ('a, 'e) Exit.t * int (* exit, expires_at_ms; 0 = never expires *)

type ('k, 'a, 'e) cache = {
  capacity : int;
  ttl_ms : ('a, 'e) Exit.t -> int;
  now_ms : unit -> int;
  lookup : ('k, 'a, 'e) lookup;
  contract : Runtime_contract.t;
  lock : Eta.Sync_lock.t;
  table : ('k, ('k, 'a, 'e) status) Hashtbl.t;
  order : 'k Stdlib.Queue.t;
}

(* [create] is an effect because the runtime contract is only available inside
   an effect context. It grabs the contract and stashes it (Pool's pattern). *)
let create ~capacity ~ttl_ms ~now_ms ~lookup =
  Effect.Expert.make ~leaf_name:"eta_cache_fixture.init" @@ fun context ->
  let contract = Effect.Expert.contract context in
  Exit.Ok
    {
      capacity;
      ttl_ms;
      now_ms;
      lookup;
      contract;
      lock = Eta.Sync_lock.create ();
      table = Hashtbl.create 16;
      order = Stdlib.Queue.create ();
    }

let make_pending c =
  let promise, resolver = c.contract.Runtime_contract.create_promise () in
  { promise; resolver; done_ = false }

let await_pending c p =
  (* [await_promise] suspends the fiber; hosting it in [Effect.sync] is the same
     pattern as deferred_pubsub_research and Pool's [await_promise] use. *)
  Effect.sync (fun () -> c.contract.Runtime_contract.await_promise p.promise)

let complete_pending c p exit =
  Effect.sync (fun () ->
      if p.done_ then false
      else (
        p.done_ <- true;
        c.contract.Runtime_contract.resolve_promise p.resolver exit;
        true))

let expired c at = if at = 0 then false else c.now_ms () >= at
let expire_at c ttl = if ttl <= 0 then 0 else c.now_ms () + ttl

let enforce_capacity_locked c =
  match c.capacity with
  | cap when cap > 0 ->
      let extra = Hashtbl.length c.table - cap in
      let rec drop n =
        if n <= 0 then ()
        else
          let kopt =
            if Stdlib.Queue.is_empty c.order then None
            else Some (Stdlib.Queue.take c.order)
          in
          (match kopt with
           | None -> ()
           | Some k ->
               (match Hashtbl.find_opt c.table k with
                | Some Pending _ -> drop n
                | _ -> Hashtbl.remove c.table k; drop (n - 1)))
      in
      drop extra
  | _ -> ()

let complete_locked c k exit =
  let ttl = c.ttl_ms exit in
  if ttl = 0 then Hashtbl.remove c.table k
  else Hashtbl.replace c.table k (Complete (exit, expire_at c ttl))

let get c k : (('a, 'e) Exit.t, _) Effect.t =
  let decision =
    Effect.sync (fun () ->
        Eta.Sync_lock.use c.lock (fun () ->
            match Hashtbl.find_opt c.table k with
            | Some (Complete (exit, at)) when not (expired c at) -> `Hit exit
            | Some (Pending p) -> `Wait p
            | _ ->
                let p = make_pending c in
                Hashtbl.replace c.table k (Pending p);
                Stdlib.Queue.push k c.order;
                enforce_capacity_locked c;
                `Miss p))
  in
  decision
  |> Effect.bind (function
       | `Hit exit -> Effect.pure exit
       | `Wait p -> await_pending c p
       | `Miss p ->
           c.lookup.calls <- c.lookup.calls + 1;
           let fail_next = c.lookup.fail_next in
           c.lookup.fail_next <- false;
           (if fail_next then Effect.fail `Lookup_failed else c.lookup.run k)
           |> Effect.exit
           |> Effect.bind (fun exit ->
               complete_pending c p exit
               |> Effect.bind (fun _ ->
                   Effect.sync (fun () ->
                       Eta.Sync_lock.use c.lock (fun () -> complete_locked c k exit))
                   |> Effect.bind (fun () -> Effect.pure exit))))

let invalidate c k =
  Effect.sync (fun () ->
      Eta.Sync_lock.use c.lock (fun () -> Hashtbl.remove c.table k))

let set_success c k v =
  Effect.sync (fun () ->
      Eta.Sync_lock.use c.lock (fun () ->
          complete_locked c k (Exit.ok v)))
