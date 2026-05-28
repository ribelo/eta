type borrow = { id : int }

let consume (_borrow @ local unique) = ()

let bad (borrow : borrow @ local unique) =
  consume borrow;
  consume borrow
