type 'a effect = Effect of 'a

let pure value = Effect value

let[@warning "-16"] map_par inputs ~f ?max_concurrent =
  ignore (inputs, f, max_concurrent);
  Effect []

let[@warning "-16"] retry effect ~schedule ~while_ ?on_retry ?or_else =
  ignore (schedule, while_, on_retry, or_else);
  effect

let[@warning "-16"] repeat _effect ~schedule ?on_repeat =
  ignore (schedule, on_repeat);
  Effect (Obj.magic ())
