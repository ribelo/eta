(* Branch A — Minimal Service Adapter (prototype).

   Adapts the existing [Eta_router] radix trie + the existing
   [Eta_http.Server.handler] contract, and adds the three things they do not
   connect today: method dispatch, 404, and 405 — the exact seams inn's R1/R2/R3
   evidence names.

   Design rules:
     - compiles down to Eta_http.Server.handler (the escape hatch IS the handler
       type — no private internals);
     - no environment channel: a route's dependencies are captured by its
       handler closure (ordinary OCaml), per docs/services.md;
     - route params delivered via [Req.t] alongside the raw request;
     - 404 (no path) vs 405 (path exists, wrong method) produced by the adapter.
*)
open Eta

module S = Eta_http.Server
module R = Eta_router

module Req = struct
  type t = {
    raw : Eta_http.Server.Request.t;
    params : R.Params.t;
  }

  let param t name = R.Params.get t.params name
  let path t = t.raw.Eta_http.Server.Request.path
  let method_ t = t.raw.Eta_http.Server.Request.method_
  let header t name = Eta_http.Core.Header.get name t.raw.Eta_http.Server.Request.headers
  let body t = t.raw.Eta_http.Server.Request.body
end

type route = Req.t -> (S.Response.t, S.Error.t) Effect.t

type config = {
  not_found : S.handler;
  method_not_allowed : string -> string -> S.handler;
}

let default_config = {
  not_found = S.Handler.route_not_found;
  method_not_allowed =
    (fun _method_ _path _request ->
      Effect.pure (S.Response.text ~status:405 "method not allowed\n"));
}

type t = (string * string list * route) list ref

let create () : t = ref []

let add (t : t) ?(methods = [ "GET" ]) pattern route =
  t := (pattern, methods, route) :: !t

(* Build a router keyed by pattern -> [(method, route)] list, last-wins per
   method. Then return an Eta_http.Server.handler that does path lookup +
   method dispatch, producing 404 / 405 as needed. *)
let compile ?(config = default_config) (t : t) : S.handler =
  let router : (string * route) list R.Router.t = R.Router.create () in
  List.iter
    (fun (pattern, methods, route) ->
      let existing =
        match R.Router.at router pattern with
        | Ok m -> Some m.R.Match.value
        | Error _ -> None
      in
      let merged =
        List.fold_left (fun acc m -> (m, route) :: acc)
          (Option.value existing ~default: []) methods
      in
      ignore (R.Router.remove router pattern);
      match R.Router.insert router pattern merged with
      | Ok () -> ()
      | Error _ -> ())
    (List.rev !t);
  fun request ->
    let path = request.Eta_http.Server.Request.path in
    match R.Router.at router path with
    | Error R.Error.Not_found -> config.not_found request
    | Ok { R.Match.value = table; params } ->
        let req = { Req.raw = request; params } in
        match List.assoc_opt request.Eta_http.Server.Request.method_ table with
        | Some route -> route req
        | None ->
            config.method_not_allowed request.S.Request.method_ path request
