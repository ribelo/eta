type structured_output = Core.structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}

let structured_output = Core.structured_output
let decode_error_result = Core.decode_error_result
let parse_json = Core.parse_json
let schema_value = Core.schema_value
let non_empty_list = Core.non_empty_list
let optional_non_empty = Core.optional_non_empty
let result_all = Core.result_all

let encode_embeddings_json = Embeddings.encode_embeddings_json
let encode_embeddings = Embeddings.encode_embeddings
let decode_embeddings = Embeddings.decode_embeddings

let content_text = Content.content_text
let contents_text = Content.contents_text
let message_item = Content.message_item
let function_call_item = Content.function_call_item
let input_items = Content.input_items
let chat_message_json = Content.chat_message_json

type tool_shape = Tools.tool_shape =
  | Chat_tool
  | Responses_tool

let tool_json = Tools.tool_json

type structured_output_shape = Tools.structured_output_shape =
  | Chat_response_format
  | Responses_format

let structured_output_json = Tools.structured_output_json

let encode_chat_json = Chat.encode_chat_json
let encode_chat = Chat.encode_chat
let decode_chat = Chat.decode_chat

let encode_responses_json = Responses.encode_responses_json
let encode_responses = Responses.encode_responses
let decode_responses = Responses.decode_responses

let finish_reason = Core.finish_reason
let usage = Core.usage

let provider_error_json = Error_codec.provider_error_json
let provider_error = Error_codec.provider_error
let decode_error = Error_codec.decode_error

let chat_stream_events = Stream.chat_stream_events
let responses_stream_events = Stream.responses_stream_events
let decode_stream_event = Stream.decode_stream_event
