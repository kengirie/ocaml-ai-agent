(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type t = { temperature : float; max_tokens : int }

let default = { temperature = 1.0; max_tokens = 1024 }
