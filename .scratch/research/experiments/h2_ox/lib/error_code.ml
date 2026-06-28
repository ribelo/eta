type t = NoError | ProtocolError | InternalError | FlowControlError
       | SettingsTimeout | StreamClosed | FrameSizeError | RefusedStream
       | Cancel | CompressionError | ConnectError | EnhanceYourCalm
       | InadequateSecurity | Http11Required

let of_int32 = function
  | 0l -> NoError | 1l -> ProtocolError | 2l -> InternalError
  | 3l -> FlowControlError | 4l -> SettingsTimeout | 5l -> StreamClosed
  | 6l -> FrameSizeError | 7l -> RefusedStream | 8l -> Cancel
  | 9l -> CompressionError | 10l -> ConnectError | 11l -> EnhanceYourCalm
  | 12l -> InadequateSecurity | 13l -> Http11Required
  | _ -> ProtocolError
