(* Tests for the DSML encoder/parser.

   Oracles:
   - the two Quick Start examples documented in DeepSeek-V4's encoding README;
   - the canonical bash tool-call DSML string asserted by this repo's own C
     tests (ds4_server.c:test_tool_memory_max_ids_prunes_oldest). *)

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n" name
  end

let check_eq name ~expect ~got =
  if expect = got then Printf.printf "ok   - %s\n" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n  expect: %S\n  got:    %S\n" name expect got
  end

open Dsml

(* substring test (the library keeps its own internal version private) *)
let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec at i j =
    j >= m || (i + j < n && s.[i + j] = sub.[j] && at i (j + 1))
  in
  let rec loop i = i + m <= n && (at i 0 || loop (i + 1)) in
  m = 0 || loop 0

let dsml = dsml_token

type edit = { path : string; line : int }

let mk_edit path line = { path; line }

let edit_codec =
  let open Codec in
  Invoke.map "edit" mk_edit
  |> Invoke.param ~enc:(fun e -> e.path) "path" string
  |> Invoke.param ~enc:(fun e -> e.line) "line" int
  |> Invoke.seal

(* A typed dispatch over a heterogeneous block: known tools to records, the rest
   to the generic [tool_call]. *)
type call = An_edit of edit | Other of tool_call

let call_codec =
  Codec.choice
    ~default:
      (Codec.map
         ~dec:(fun tc -> Other tc)
         ~enc:(function Other tc -> tc | _ -> assert false)
         Codec.dynamic)
    [
      Codec.case
        ~inject:(fun e -> An_edit e)
        ~project:(function An_edit e -> Some e | _ -> None)
        edit_codec;
    ]

(* Canonical one-call DSML block (matches the C repo's a_dsml literal). *)
let bash_a_block =
  Printf.sprintf
    "\n\n\
     <%stool_calls>\n\
     <%sinvoke name=\"bash\">\n\
     <%sparameter name=\"command\" string=\"true\">a</%sparameter>\n\
     </%sinvoke>\n\
     </%stool_calls>"
    dsml dsml dsml dsml dsml dsml

let () =
  (* T1: README Quick Start — encode. *)
  let got =
    encode_messages Thinking
      [ system "You are a helpful assistant."; user "What is 2+2?" ]
  in
  let expect =
    bos_token ^ "You are a helpful assistant." ^ user_token ^ "What is 2+2?"
    ^ assistant_token ^ thinking_start_token
  in
  check_eq "encode quick-start" ~expect ~got;

  (* T2: README Quick Start — parse. *)
  let p =
    parse_message_from_completion_text Thinking
      ("Simple arithmetic." ^ thinking_end_token ^ "2 + 2 = 4." ^ eos_token)
  in
  check "parse quick-start reasoning"
    (p.reasoning_content = "Simple arithmetic.");
  check "parse quick-start content" (p.content = "2 + 2 = 4.");
  check "parse quick-start no tools" (p.tool_calls = []);

  (* T3: parse a single tool call out of a thinking completion. *)
  let completion =
    "need a tool" ^ thinking_end_token ^ "I will inspect." ^ bash_a_block
    ^ eos_token
  in
  let p = parse_message_from_completion_text Thinking completion in
  check "parse tool reasoning" (p.reasoning_content = "need a tool");
  check "parse tool content" (p.content = "I will inspect.");
  (match p.tool_calls with
  | [ tc ] ->
      check "parse tool name" (tc.name = "bash");
      check_eq "parse tool arguments" ~expect:{|{"command":"a"}|}
        ~got:tc.arguments
  | _ -> check "parse tool single call" false);

  (* T4: encode an assistant tool call -> canonical block matches the C repo. *)
  let got =
    encode_messages Thinking
      [
        user "do it";
        assistant
          ~tool_calls:
            [ tool_call ~name:"bash" ~arguments:{|{"command":"a"}|} () ]
          ();
      ]
  in
  check "encode tool block matches C repo vector" (contains got bash_a_block);

  (* T5: chat mode closes thinking immediately after the assistant prefix. *)
  let got = encode_messages Chat [ system "S"; user "U" ] in
  let expect =
    bos_token ^ "S" ^ user_token ^ "U" ^ assistant_token ^ thinking_end_token
  in
  check_eq "encode chat mode" ~expect ~got;

  (* T6: reasoning_effort Max prepends the maximum-reasoning prefix (after BOS,
     before the system message). *)
  let got =
    encode_messages ~reasoning_effort:Max Thinking [ system "S"; user "U" ]
  in
  check "reasoning-effort max prefix"
    (String.starts_with
       ~prefix:
         (bos_token
        ^ "Reasoning Effort: Absolute maximum with no shortcuts permitted.")
       got);

  (* T7: numeric (string="false") parameter round-trips through JSON. *)
  let completion =
    thinking_end_token ^ "ok"
    ^ Printf.sprintf
        "\n\n\
         <%stool_calls>\n\
         <%sinvoke name=\"f\">\n\
         <%sparameter name=\"count\" string=\"false\">5</%sparameter>\n\
         </%sinvoke>\n\
         </%stool_calls>"
        dsml dsml dsml dsml dsml dsml
    ^ eos_token
  in
  let p = parse_message_from_completion_text Thinking completion in
  (match p.tool_calls with
  | [ tc ] ->
      check_eq "numeric param arguments" ~expect:{|{"count":5}|}
        ~got:tc.arguments
  | _ -> check "numeric param single call" false);

  (* T8: mixed string + numeric params keep order and JSON formatting. *)
  let completion =
    thinking_end_token
    ^ Printf.sprintf
        "\n\n\
         <%stool_calls>\n\
         <%sinvoke name=\"run\">\n\
         <%sparameter name=\"cmd\" string=\"true\">ls</%sparameter>\n\
         <%sparameter name=\"count\" string=\"false\">5</%sparameter>\n\
         </%sinvoke>\n\
         </%stool_calls>"
        dsml dsml dsml dsml dsml dsml dsml dsml
    ^ eos_token
  in
  let p = parse_message_from_completion_text Thinking completion in
  (match p.tool_calls with
  | [ tc ] ->
      check_eq "mixed param arguments" ~expect:{|{"cmd":"ls","count":5}|}
        ~got:tc.arguments
  | _ -> check "mixed param single call" false);

  (* T9: JSON via jsont — compact output, member order preserved. *)
  check_eq "json compact" ~expect:{|{"a":1,"b":"x"}|}
    ~got:
      (Json.Value.to_string (Json.Value.of_string_exn {|{ "a": 1, "b": "x" }|}));
  check_eq "json roundtrip" ~expect:{|{"a":1,"b":[1,2]}|}
    ~got:(Json.Value.to_string (Json.Value.of_string_exn {|{"a":1,"b":[1,2]}|}));

  (* T10: bytesrw I/O boundary agrees with the pure functions. *)
  let msgs = [ system "You are a helpful assistant."; user "What is 2+2?" ] in
  let buf = Buffer.create 256 in
  let w = Bytesrw.Bytes.Writer.of_buffer buf in
  encode_messages_to_writer w Thinking msgs;
  Bytesrw.Bytes.Writer.write_eod w;
  check_eq "bytesrw writer == encode_messages"
    ~expect:(encode_messages Thinking msgs)
    ~got:(Buffer.contents buf);
  let r =
    Bytesrw.Bytes.Reader.of_string
      ("Simple." ^ thinking_end_token ^ "4." ^ eos_token)
  in
  let p = parse_message_from_reader Thinking r in
  check "bytesrw reader parses"
    (p.reasoning_content = "Simple." && p.content = "4.");

  (* T11: typed invoke codec (combinator style) encodes and decodes. *)
  let block = Codec.encode edit_codec [ { path = "/tmp/x.c"; line = 42 } ] in
  (match Codec.decode edit_codec block with
  | Ok [ e ] ->
      check "typed codec roundtrip" (e.path = "/tmp/x.c" && e.line = 42)
  | _ -> check "typed codec roundtrip" false);

  (* T12: the same block decodes generically via the dynamic codec. *)
  (match Codec.decode Codec.dynamic block with
  | Ok [ tc ] ->
      check_eq "typed block via dynamic"
        ~expect:{|{"path":"/tmp/x.c","line":42}|} ~got:tc.arguments
  | _ -> check "typed block via dynamic" false);

  (* T13: choice codec dispatches a mixed block by tool name. *)
  let block =
    Codec.encode call_codec
      [
        An_edit { path = "/a"; line = 1 };
        Other (tool_call ~name:"bash" ~arguments:{|{"command":"ls"}|} ());
      ]
  in
  (match Codec.decode call_codec block with
  | Ok [ An_edit e; Other tc ] ->
      check "choice roundtrip" (e.path = "/a" && e.line = 1 && tc.name = "bash")
  | _ -> check "choice roundtrip" false);

  (* T14: streaming decode, fed byte-by-byte, matches the batch parser. *)
  let completion =
    "reason" ^ thinking_end_token ^ "hello " ^ bash_a_block ^ eos_token
  in
  let s = Stream.create Thinking in
  let evs = ref [] in
  String.iter
    (fun c -> evs := !evs @ Stream.feed s (String.make 1 c))
    completion;
  evs := !evs @ Stream.finish s;
  let collect f = List.filter_map f !evs in
  let reasoning =
    String.concat ""
      (collect (function Stream.Reasoning r -> Some r | _ -> None))
  in
  let content =
    String.concat ""
      (collect (function Stream.Content c -> Some c | _ -> None))
  in
  let calls = collect (function Stream.Tool_call c -> Some c | _ -> None) in
  let is_done =
    List.exists (function Stream.Done -> true | _ -> false) !evs
  in
  check "stream reasoning" (reasoning = "reason");
  check "stream content" (content = "hello ");
  check "stream tool call"
    (match calls with
    | [ tc ] -> tc.name = "bash" && tc.arguments = {|{"command":"a"}|}
    | _ -> false);
  check "stream done" is_done;

  (* T15: Tool.v builds the OpenAI tool object. *)
  let params =
    Json.Value.of_string_exn
      {|{"type":"object","properties":{"command":{"type":"string"}}}|}
  in
  check_eq "tool schema"
    ~expect:
      {|{"type":"function","function":{"name":"bash","description":"run a shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}|}
    ~got:
      (Json.Value.to_string
         (Tool.v ~name:"bash" ~description:"run a shell command"
            ~parameters:params ()));

  (* T16: a sealed invoke codec derives its parameters JSON Schema. *)
  check_eq "codec schema"
    ~expect:
      {|{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"}},"required":["path","line"]}|}
    ~got:(Json.Value.to_string (Codec.schema edit_codec));

  (* T17: decode_arguments turns a JSON arguments object into the typed value. *)
  check "codec decode_arguments"
    (match
       Codec.decode_arguments edit_codec {|{"path":"/tmp/x.c","line":42}|}
     with
    | Ok e -> e.path = "/tmp/x.c" && e.line = 42
    | Error _ -> false);

  check "codec decode_arguments error"
    (match Codec.decode_arguments edit_codec {|{"path":"/tmp/x.c"}|} with
    | Error _ -> true
    | Ok _ -> false);

  if !failures = 0 then Printf.printf "\nAll tests passed.\n"
  else begin
    Printf.printf "\n%d test(s) failed.\n" !failures;
    exit 1
  end
