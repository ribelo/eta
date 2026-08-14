type context = { mutable state : int }

let bad (x @ contended) = x.state <- 1
