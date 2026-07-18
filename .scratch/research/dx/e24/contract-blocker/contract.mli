type 'a effect

val map_par :
  'a list ->
  f:('a -> 'b effect) ->
  ?max_concurrent:int ->
  'b list effect

val retry :
  'a effect ->
  schedule:'schedule ->
  while_:('err -> bool) ->
  ?on_retry:'on_retry ->
  ?or_else:'or_else ->
  'a effect

val repeat :
  'a effect -> schedule:'schedule -> ?on_repeat:'on_repeat -> 'output effect

val pure : 'a -> 'a effect
