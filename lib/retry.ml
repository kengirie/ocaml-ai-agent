(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type config = {
  max_attempts : int;
  min_wait : float;
  max_wait : float;
  multiplier : float;
}

let default = { max_attempts = 5; min_wait = 1.0; max_wait = 64.0; multiplier = 2.0 }

let delay_after config ~attempt =
  Float.min config.max_wait
    (config.min_wait *. (config.multiplier ** float_of_int (attempt - 1)))

let retryable_status code = code = 408 || code = 429 || code >= 500

let run ~sleep ?(config = default) ~on_retry f =
  let rec go attempt =
    match f () with
    | Ok v -> v
    | Error (`Fatal reason) -> failwith reason
    | Error (`Retryable reason) when attempt >= config.max_attempts ->
        failwith
          (Printf.sprintf "%s (giving up after %d attempts)" reason
             config.max_attempts)
    | Error (`Retryable reason) ->
        let delay = delay_after config ~attempt in
        on_retry ~attempt ~max:config.max_attempts ~delay ~reason;
        sleep delay;
        go (attempt + 1)
  in
  go 1
