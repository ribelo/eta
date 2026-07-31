let checked_total ~max_bytes ~total ~chunk_length =
  if chunk_length > max_bytes - total then
    let actual =
      if chunk_length > max_int - total then max_int
      else total + chunk_length
    in
    Error actual
  else Ok (total + chunk_length)
