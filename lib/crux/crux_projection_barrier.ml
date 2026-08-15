let seed_incarnation_counter packed_root next =
  let root : Crux_root.Root.t = Obj.obj packed_root in
  Crux_root.Root.set_projection_incarnation_for_test root next
