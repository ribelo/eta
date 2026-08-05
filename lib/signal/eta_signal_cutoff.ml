type 'a t = { suppress : published:'a -> candidate:'a -> bool }

let suppress cutoff = cutoff.suppress

let always = { suppress = (fun ~published:_ ~candidate:_ -> true) }
let never = { suppress = (fun ~published:_ ~candidate:_ -> false) }

let phys_equal =
  { suppress = (fun ~published ~candidate -> published == candidate) }

let of_equal equal =
  { suppress = (fun ~published ~candidate -> equal published candidate) }

let of_compare compare =
  { suppress = (fun ~published ~candidate -> compare published candidate = 0) }
