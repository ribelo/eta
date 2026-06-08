val program :
  unit ->
  (< audit_fetch : 'a -> 'b; audit_get : 'c -> 'd; audit_query : 'e -> 'c;
     audit_run : 'd -> 'a; billing_fetch : 'f -> 'e; billing_get : 'g -> 'h;
     billing_query : 'i -> 'g; billing_run : 'h -> 'f;
     cache_fetch : 'j -> 'i; cache_get : 'k -> 'l; cache_query : 'm -> 'k;
     cache_run : 'l -> 'j; feature_get : 'n -> 'o; feature_query : 'p -> 'n;
     notify_fetch : 'q -> 'p; notify_get : 'r -> 's; notify_query : 't -> 'r;
     notify_run : 's -> 'q; order_fetch : 'u -> 'm; order_get : 'v -> 'w;
     order_query : 'x -> 'v; order_run : 'w -> 'u; search_fetch : 'y -> 't;
     search_get : 'z -> 'a1; search_query : 'b -> 'z; search_run : 'a1 -> 'y;
     user_fetch : 'b1 -> 'x; user_get : 'c1 -> 'd1; user_query : int -> 'c1;
     user_run : 'd1 -> 'b1; .. >,
   'e1, 'o)
  Effet.Effect.t
val run : unit -> int
