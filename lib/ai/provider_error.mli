(** Shared lossless HTTP-response envelope for nominal provider errors. *)

type 'payload http_response = {
  status : int;
  headers : Types.headers;
  payload : 'payload option;
  raw_body : Types.raw_json;
}
