include Frame_conversion

module Format = struct
  let encode frame =
    frame |> to_protocol |> Protocol.encode_json |> Bytes.of_string

  let decode bytes =
    match Protocol.decode_json ~max_frame_bytes:max_int (Bytes.to_string bytes) with
    | Error message -> Error (protocol_error message)
    | Ok frame -> of_protocol frame
end
