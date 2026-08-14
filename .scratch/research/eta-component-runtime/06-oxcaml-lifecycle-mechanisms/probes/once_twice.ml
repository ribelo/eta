let bad (f : (unit -> unit) @ once) = f (); f ()
