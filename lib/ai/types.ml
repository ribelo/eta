type raw_json = string

type headers = Eta_http.Core.Header.t
type api_key = string Eta_redacted.t
let api_key value = Eta_redacted.make ~label:"api_key" value

type model = string
type provider_name = string

type audio_format = Pcm16 | G711_alaw | G711_ulaw | Mp3 | Opus | Wav

type audio_data = Base64 of string | Bytes of bytes

type audio = {
  data : audio_data;
  format : audio_format;
  transcript : string option;
}

type media = {
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

type tool_call = {
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

type finish_reason =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string

type input_token_usage = {
  uncached : int option;
  total : int option;
  cache_read : int option;
  cache_write : int option;
}

type output_token_usage = {
  total : int option;
  text : int option;
  reasoning : int option;
}

type usage = {
  input_tokens : input_token_usage;
  output_tokens : output_token_usage;
  raw : (string * string) list;
}

type response = {
  id : string option;
  model : model option;
  message : message;
  finish_reasons : finish_reason list;
  usage : usage option;
  replay_items : raw_json list;
  raw : raw_json option;
}

type tool = {
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
  replay_items : raw_json list;
  stream : bool;
}

type binary_file = {
  filename : string;
  content_type : string;
  data : bytes;
}

module Embedding = struct
  type input =
    | Text of string
    | Texts of string list
    | Tokens of int list
    | Token_batches of int list list
    | Raw_json of raw_json

  type request = {
    model : model;
    input : input;
    encoding_format : string option;
    dimensions : int option;
    user : string option;
  }

  type vector =
    | Float of float list
    | Base64 of string

  type item = {
    embedding : vector;
    index : int option;
  }

  type usage = {
    input_tokens : int option;
    total_tokens : int option;
    raw : (string * string) list;
  }

  type response = {
    id : string option;
    model : model option;
    embeddings : item list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Image = struct
  type generated = {
    url : string option;
    base64 : string option;
    revised_prompt : string option;
  }

  type request = {
    model : model option;
    prompt : string;
    n : int option;
    size : string option;
    quality : string option;
    response_format : string option;
    user : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    created : int option;
    images : generated list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Speech = struct
  type request = {
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

  type response = {
    text : string option;
    usage : usage option;
    raw : raw_json option;
  }
end

module Rerank = struct
  type request = {
    model : model;
    query : string;
    documents : string list;
    top_n : int option;
  }

  type result = {
    index : int;
    score : float option;
    document : string option;
  }

  type response = {
    id : string option;
    model : model option;
    provider : string option;
    results : result list;
    usage : usage option;
    raw : raw_json option;
  }
end

module Video = struct
  type request = {
    model : model;
    prompt : string;
    aspect_ratio : string option;
    duration : int option;
    resolution : string option;
    extra : (string * Json.t) list;
  }

  type response = {
    id : string;
    generation_id : string option;
    status : string option;
    polling_url : string option;
    urls : string list;
    error : string option;
    usage : usage option;
    raw : raw_json option;
  }

  type content_request = {
    job_id : string;
    index : int option;
  }

  type content = {
    content_type : string option;
    bytes : bytes;
  }
end

type ai_error =
  | Eta_http_error of Eta_http.Error.t
  | Provider_error of {
      provider : provider_name;
      status : int option;
      code : string option;
      message : string;
      raw : raw_json option;
      retry_after_s : int option;
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

type ai_error_category =
  | Transient
  | Context_overflow
  | Account_limit
  | Quota_budget
  | Billing
  | Other

type ai_failure = {
  category : ai_error_category;
  status : int option;
  retryable : bool;
  retry_after_s : int option;
  diagnostic : string;
}

type sse_event = {
  event : string option;
  data : raw_json;
}

type tool_call_delta = {
  index : int option;
  id : string option;
  name : string option;
  arguments_json_delta : string;
}

type stream_event =
  | Stream_message_start of {
      id : string option;
      model : model option;
      raw : raw_json option;
    }
  | Stream_reasoning_delta of string
  | Stream_content_delta of string
  | Stream_tool_call_delta of tool_call_delta
  | Stream_response of response
  | Stream_finish of finish_reason list
  | Stream_error of ai_error
  | Stream_done

type capabilities = {
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
  auth_headers : (api_key -> headers);
  capabilities : capabilities;
  encode_chat : (chat_request -> (raw_json, ai_error) result);
  decode_chat : (raw_json -> (response, ai_error) result);
  encode_embeddings : (Embedding.request -> (raw_json, ai_error) result);
  decode_embeddings : (raw_json -> (Embedding.response, ai_error) result);
  decode_stream_event : (sse_event -> (stream_event list, ai_error) result);
  decode_error : (status:int -> headers:headers -> raw_json -> ai_error);
}
