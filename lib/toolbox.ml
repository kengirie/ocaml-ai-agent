(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Each tool closes over one Eio capability and nothing else, so what it can
   reach is fixed at the call site, not by the model. *)

let read ~dir =
  let args =
    let open Schema in
    let+ path =
      string "path"
        ~description:"path of the file to read, relative to the root directory"
    in
    path
  in
  Tool.v ~name:"read"
    ~description:"Read a UTF-8 text file and return its contents." args
    (fun path -> Eio.Path.load Eio.Path.(dir / path))

let write ~dir =
  let args =
    let open Schema in
    let+ path =
      string "path" ~description:"destination path, relative to the root directory"
    and+ content = string "content" ~description:"new file contents" in
    (path, content)
  in
  Tool.v ~name:"write"
    ~description:"Create or overwrite a UTF-8 text file under the root." args
    (fun (path, content) ->
      let target = Eio.Path.(dir / path) in
      Eio.Path.save ~create:(`Or_truncate 0o644) target content;
      Printf.sprintf "wrote %d bytes to %s" (String.length content) path)

let dns ~net =
  let args =
    let open Schema in
    let+ host =
      string "host" ~description:"hostname to resolve, e.g. \"example.com\""
    in
    host
  in
  Tool.v ~name:"dns"
    ~description:"Resolve a hostname to IP addresses via getaddrinfo." args
    (fun host ->
      match Eio.Net.getaddrinfo_stream net host with
      | exception Eio.Io _ -> Printf.sprintf "could not resolve %s" host
      | [] -> Printf.sprintf "no addresses found for %s" host
      | addrs ->
          addrs
          |> List.filter_map (function
               | `Tcp (ip, _) -> Some (Format.asprintf "%a" Eio.Net.Ipaddr.pp ip)
               | `Unix _ -> None)
          |> List.sort_uniq String.compare
          |> String.concat "\n")

let bash ~proc =
  let args =
    let open Schema in
    let+ command =
      string "command" ~description:"shell command line, run with 'bash -c'"
    in
    command
  in
  Tool.v ~name:"bash"
    ~description:"Run a shell command and capture its combined output." args
    (fun command ->
      Eio.Process.parse_out proc Eio.Buf_read.take_all [ "bash"; "-c"; command ])
