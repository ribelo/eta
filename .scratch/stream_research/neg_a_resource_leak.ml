(* Predicted error: the expression has type [ `Closed ] but an expression was expected of type
   S_a_channel_core.Channel.open_scope.

  Property defended: S-A's resource constructor cannot be called without the
   scoped-token shape it claims to require. *)

let _ =
  let scope = (`Closed : [ `Closed ]) in
  S_a_channel_core.Stream.scoped_file ~scope "bad" [ 1; 2; 3 ]
