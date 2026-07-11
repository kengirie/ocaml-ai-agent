(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Exponential-backoff retry for transient API failures.

    Modelled on OpenHands' RetryMixin: a bounded number of attempts with
    exponentially growing waits, a listener invoked before each sleep, and a
    hard distinction between retryable failures (rate limits, server errors,
    connection drops) and fatal ones (bad requests, auth) that fail at once. *)

type config = {
  max_attempts : int;  (** total attempts, including the first *)
  min_wait : float;  (** seconds before the first retry *)
  max_wait : float;  (** ceiling on any single wait *)
  multiplier : float;  (** wait growth factor per attempt *)
}

val default : config
(** [{ max_attempts = 5; min_wait = 1.0; max_wait = 64.0; multiplier = 2.0 }] *)

val delay_after : config -> attempt:int -> float
(** [delay_after config ~attempt] is the wait after failed attempt [attempt]
    (1-based): [min max_wait (min_wait *. multiplier ^ (attempt - 1))]. *)

val retryable_status : int -> bool
(** HTTP statuses worth retrying: 408, 429, and every 5xx (including
    Anthropic's 529 "overloaded"). Other 4xx are fatal. *)

val run :
  sleep:(float -> unit) ->
  ?config:config ->
  on_retry:(attempt:int -> max:int -> delay:float -> reason:string -> unit) ->
  (unit -> ('a, [ `Retryable of string | `Fatal of string ]) result) ->
  'a
(** [run ~sleep ~on_retry f] calls [f] up to [config.max_attempts] times.
    [Ok v] returns [v]; [Error (`Fatal m)] raises [Failure m] immediately;
    [Error (`Retryable m)] calls [on_retry] with the failed attempt number and
    the coming delay, sleeps, and tries again — raising [Failure] once the
    attempts are exhausted. *)
