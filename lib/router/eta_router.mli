(** High-performance zero-copy URL path router.

    This is an idiomatic OxCaml port of the radix-trie router idea, with named
    and catch-all parameters, prefix/suffix parameter patterns, and escaped
    braces in static segments.

    Example:
    {[
      let router = Eta_router.Router.create () in
      match Eta_router.Router.insert router "/users/{id}" "user" with
      | Ok () -> ()
      | Error _ -> assert false;

      match Eta_router.Router.at router "/users/978" with
      | Ok m ->
          assert (Eta_router.Params.get m.params "id" = Some "978");
          assert (m.value = "user")
      | Error _ -> assert false
    ]} *)

module Error = Router_error
module Params = Params
module Match = Match
module Router = Router

(** {1 Internal building blocks}

    These modules are exposed primarily for testing and benchmarking. They are
    not part of the stable public API. *)

module Escape = Escape
module Route = Route
