(* MUST FAIL when temporarily added to dune.

   Property: explicit object combine surfaces method-name collisions at the
   combine site. *)

open Layer_research

let _bad =
  Merge_explicit.Layer.merge (Merge_explicit.db_layer ())
    (Merge_explicit.http_layer ())
    ~combine:(fun db http ->
      object
        method service = db
        method service = http
      end)
