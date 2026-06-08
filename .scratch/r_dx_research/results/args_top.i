val program :
  user_query:(int -> 'a) ->
  user_get:('a -> 'b) ->
  user_run:('b -> 'c) ->
  user_fetch:('c -> 'd) ->
  order_query:('d -> 'e) ->
  order_get:('e -> 'f) ->
  order_run:('f -> 'g) ->
  order_fetch:('g -> 'h) ->
  cache_query:('h -> 'i) ->
  cache_get:('i -> 'j) ->
  cache_run:('j -> 'k) ->
  cache_fetch:('k -> 'l) ->
  billing_query:('l -> 'm) ->
  billing_get:('m -> 'n) ->
  billing_run:('n -> 'o) ->
  billing_fetch:('o -> 'p) ->
  audit_query:('p -> 'q) ->
  audit_get:('q -> 'r) ->
  audit_run:('r -> 's) ->
  audit_fetch:('s -> 't) ->
  search_query:('t -> 'u) ->
  search_get:('u -> 'v) ->
  search_run:('v -> 'w) ->
  search_fetch:('w -> 'x) ->
  notify_query:('x -> 'y) ->
  notify_get:('y -> 'z) ->
  notify_run:('z -> 'a1) ->
  notify_fetch:('a1 -> 'b1) ->
  feature_query:('b1 -> 'c1) ->
  feature_get:('c1 -> 'd1) -> ('e1, 'f1, 'd1) Effet.Effect.t
val run : unit -> int
