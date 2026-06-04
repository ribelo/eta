type raw_json = string

type headers = Eta_http.Core.Header.t
type api_key = string Eta_redacted.t
let api_key value = Eta_redacted.make ~label:"api_key" value

type model = string
type provider_name = string

type audio_format : immutable_data = Pcm16 | G711_alaw | G711_ulaw | Mp3 | Opus | Wav

type audio_data = Base64 of string | Bytes of bytes

type audio = {
  data : audio_data;
  format : audio_format;
  transcript : string option;
}

type media : immutable_data = {
  url : string;
  detail : string option;
}

type content =
  | Text of string
  | Json of raw_json
  | Image of media
  | Audio of audio
  | Video of media

let audio_pcm16_base64 ?transcript data = Audio { data = Base64 data; format = Pcm16; transcript }
let url ?detail url = Image { url; detail }
let video_url ?detail url = Video { url; detail }

type tool_call : immutable_data = {
  id : string;
  name : string;
  arguments_json : raw_json;
}

type message =
  | System of string
  | User of content list
  | Assistant of {
      content : content list;
      tool_calls : tool_call list;
    }
  | Tool of {
      tool_call_id : string;
      content : content list;
    }

type prompt = message list

type finish_reason : immutable_data =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string

type usage : immutable_data = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  raw : (string * string) list;
}

type response = {
  id : string option;
  model : model option;
  message : message;
  finish_reasons : finish_reason list;
  usage : usage option;
  raw : raw_json option;
}

type tool : immutable_data = {
  name : string;
  description : string option;
  input_schema_json : raw_json;
  strict : bool option;
}

type chat_request = {
  model : model;
  prompt : prompt;
  tools : tool list;
  temperature : float option;
  max_output_tokens : int option;
  stream : bool;
}

type binary_file = {
  filename : string;
  content_type : string;
  data : bytes;
}

module Embedding = struct
  type input : immutable_data =
    | Text of string
    | Texts of string list
    | Tokens of int list
    | Token_batches of int list list
    | Raw_json of raw_json

  type request : immutable_data = {
    model : model;
    input : input;
    encoding_format : string option;
    dimensions : int option;
    user : string option;
  }

  type vector : immutable_data =
    | Float of float list
    | Base64 of string

  type item : immutable_data = {
    embedding : vector;
    index : int option;
  }

  type usage : immutable_data = {
    input_tokens : int option;
    total_tokens : int option;
    raw : (string * string) list;
  }

  type response : immutable_data = {
    id : string option;
    model : model option;
    embeddings : item list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Image = struct
  type generated : immutable_data = {
    url : string option;
    base64 : string option;
    revised_prompt : string option;
  }

  type request : immutable_data = {
    model : model option;
    prompt : string;
    n : int option;
    size : string option;
    quality : string option;
    response_format : string option;
    user : string option;
    extra : (string * Json.t) list;
  }

  type response : immutable_data = {
    created : int option;
    images : generated list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Speech = struct
  type request : immutable_data = {
    model : model;
    input : string;
    voice : string;
    response_format : string option;
    speed : float option;
    instructions : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    content_type : string option;
    audio : bytes;
  }
end

module Transcription = struct
  type request = {
    model : model;
    file : binary_file;
    language : string option;
    prompt : string option;
    response_format : string option;
    temperature : float option;
    extra_fields : (string * string) list;
  }

  type response : immutable_data = {
    text : string option;
    usage : usage option;
    raw : raw_json option;
  }
end

module Rerank = struct
  type request : immutable_data = {
    model : model;
    query : string;
    documents : string list;
    top_n : int option;
  }

  type result : immutable_data = {
    index : int;
    score : float option;
    document : string option;
  }

  type response : immutable_data = {
    id : string option;
    model : model option;
    provider : string option;
    results : result list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Video = struct
  type request : immutable_data = {
    model : model;
    prompt : string;
    aspect_ratio : string option;
    duration : int option;
    resolution : string option;
    extra : (string * Json.t) list;
  }

  type response : immutable_data = {
    id : string;
    generation_id : string option;
    status : string option;
    polling_url : string option;
    urls : string list;
    error : string option;
    usage : usage option;
    raw : raw_json option;
  }

  type content_request : immutable_data = {
    job_id : string;
    index : int option;
  }

  type content = {
    content_type : string option;
    bytes : bytes;
  }
end

type ai_error : immutable_data =
  | Eta_http_error of Eta_http.Error.t
  | Provider_error of {
      provider : provider_name;
      status : int option;
      code : string option;
      message : string;
      raw : raw_json option;
    }
  | Decode_error of {
      provider : provider_name;
      message : string;
      raw : raw_json option;
    }
  | Invalid_tool of {
      name : string;
      message : string;
    }
  | Unsupported of {
      provider : provider_name;
      feature : string;
    }

type sse_event : immutable_data = {
  event : string option;
  data : raw_json;
}

type tool_call_delta : immutable_data = {
  index : int option;
  id : string option;
  name : string option;
  arguments_json_delta : string;
}

type stream_event : immutable_data =
  | Stream_message_start of {
      id : string option;
      model : model option;
      raw : raw_json option;
    }
  | Stream_content_delta of string
  | Stream_tool_call_delta of tool_call_delta
  | Stream_finish of finish_reason list
  | Stream_error of ai_error
  | Stream_done

type capabilities : immutable_data = {
  streaming : bool;
  tools : bool;
  tool_choice : bool;
  structured_outputs : bool;
  text : bool;
  image_input : bool;
  audio_input : bool;
  video_input : bool;
  embeddings : bool;
  image_generation : bool;
  speech : bool;
  transcription : bool;
  rerank : bool;
  video_generation : bool;
}

type provider = {
  name : provider_name;
  base_url : string;
  chat_path : string;
  embeddings_path : string option;
  auth_headers : (api_key -> headers) @@ many;
  capabilities : capabilities;
  encode_chat : (chat_request -> (raw_json, ai_error) result) @@ many;
  decode_chat : (raw_json -> (response, ai_error) result) @@ many;
  encode_embeddings : (Embedding.request -> (raw_json, ai_error) result) @@ many;
  decode_embeddings : (raw_json -> (Embedding.response, ai_error) result) @@ many;
  decode_stream_event : (sse_event -> (stream_event list, ai_error) result) @@ many;
  decode_error : (status:int -> headers:headers -> raw_json -> ai_error) @@ many;
}
