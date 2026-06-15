(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Ready-made tools. Each closes over an Eio capability (a directory, the
   process manager, or the network), so its reach is exactly what the caller
   granted. *)

let read ~dir =
  let codec =
    let open Dsml.Codec in
    Invoke.map "read" (fun path -> path)
    |> Invoke.param ~enc:Fun.id "path" string
         ~description:"path of the file to read, relative to the root directory"
    |> Invoke.seal
  in
  Tool.v ~description:"Read a UTF-8 text file and return its contents." codec
    (fun path -> Eio.Path.load Eio.Path.(dir / path))

let write ~dir =
  let codec =
    let open Dsml.Codec in
    Invoke.map "write" (fun path content -> (path, content))
    |> Invoke.param ~enc:fst "path" string
         ~description:"destination path, relative to the root directory"
    |> Invoke.param ~enc:snd "content" string ~description:"new file contents"
    |> Invoke.seal
  in
  Tool.v ~description:"Create or overwrite a UTF-8 text file under the root."
    codec (fun (path, content) ->
      let target = Eio.Path.(dir / path) in
      Eio.Path.save ~create:(`Or_truncate 0o644) target content;
      Printf.sprintf "wrote %d bytes to %s" (String.length content) path)

let dns ~net =
  let codec =
    let open Dsml.Codec in
    Invoke.map "dns" (fun host -> host)
    |> Invoke.param ~enc:Fun.id "host" string
         ~description:"hostname to resolve, e.g. \"example.com\""
    |> Invoke.seal
  in
  Tool.v ~description:"Resolve a hostname to IP addresses via getaddrinfo."
    codec (fun host ->
      match Eio.Net.getaddrinfo_stream net host with
      | exception Eio.Exn.Io _ -> Printf.sprintf "could not resolve %s" host
      | [] -> Printf.sprintf "no addresses found for %s" host
      | addrs ->
          addrs
          |> List.filter_map (function
            | `Tcp (ip, _) -> Some (Format.asprintf "%a" Eio.Net.Ipaddr.pp ip)
            | `Unix _ -> None)
          |> List.sort_uniq String.compare
          |> String.concat "\n")

let bash ~proc =
  let codec =
    let open Dsml.Codec in
    Invoke.map "bash" (fun command -> command)
    |> Invoke.param ~enc:Fun.id "command" string
         ~description:"shell command line, run with 'bash -c'"
    |> Invoke.seal
  in
  Tool.v ~description:"Run a shell command and capture its combined output."
    codec (fun command ->
      Eio.Process.parse_out proc Eio.Buf_read.take_all [ "bash"; "-c"; command ])
