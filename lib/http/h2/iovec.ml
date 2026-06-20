type 'a t = 'a Connection.iovec = {
  buffer : 'a;
  off : int;
  len : int;
}

let buffer t = t.buffer
let off t = t.off
let len t = t.len

let lengthv iovecs =
  List.fold_left (fun acc t -> acc + t.len) 0 iovecs
