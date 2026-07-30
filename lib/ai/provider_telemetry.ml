include Observability

(* Re-export only the typed authoring surface under this compilation unit.
   Historical neutral helpers remain available from Observability via Eta_ai. *)

let with_chat_span ~error_view provider request eff =
  with_chat_span_for ~error_view provider request eff

let with_stream_span ~error_view ?time_to_first_chunk_s provider request eff =
  with_stream_span_for ~error_view ?time_to_first_chunk_s provider request eff

let with_responses_span ~error_view provider request eff =
  with_responses_span_for ~error_view provider request eff

let with_responses_stream_span ~error_view ?time_to_first_chunk_s provider
    request eff =
  with_responses_stream_span_for ~error_view ?time_to_first_chunk_s provider
    request eff

let with_embeddings_span ~error_view provider request eff =
  with_embeddings_span_for ~error_view provider request eff

let with_tool_span ~error_view ?tool_call_id ?tool_type ~tool_name eff =
  with_tool_span_for ~error_view ?tool_call_id ?tool_type ~tool_name eff
