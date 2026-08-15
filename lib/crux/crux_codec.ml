type encode_error = { message : string }
type decode_error = { message : string }

type 'a t = {
  encode : 'a -> (bytes, encode_error) result;
  decode : bytes -> ('a, decode_error) result;
}

let make ~encode ~decode = { encode; decode }
let encode codec value = codec.encode value
let decode codec bytes = codec.decode bytes
