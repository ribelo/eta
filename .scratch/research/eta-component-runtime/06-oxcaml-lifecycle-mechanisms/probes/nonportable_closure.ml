let bad () =
  let r = ref 0 in
  let f () = r := !r + 1 in
  let _ @ portable = f in
  ()
