type 'a t = 'a Connection.iovec = {
  buffer : 'a;
  off : int;
  len : int;
}

val buffer : 'a t -> 'a
val off : 'a t -> int
val len : 'a t -> int
val lengthv : 'a t list -> int
