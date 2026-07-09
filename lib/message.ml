(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type tool_call = { id : string; name : string; input : Yojson.Safe.t }

type t =
  | User of string
  | Assistant of {
      text : string;
      thinking : string;
      tool_calls : tool_call list;
    }
  | Tool_result of { id : string; content : string }
