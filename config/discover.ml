(* Build-time backend C-flag discovery.

   Emits two flag files consumed by the engine-archive rules in ../lib_metal and
   ../lib_cpu via %{read-lines:...}:

     core_cflags  - flags for the C core (ds4.c, ds4_ssd.c, ds4_distributed.c)
     objc_cflags  - flags for the Metal Objective-C backend (ds4_metal.m)

   The only platform difference is the native-arch flag and a couple of Linux
   knobs; everything else mirrors the upstream Makefile. *)

module C = Configurator.V1

let () =
  C.main ~name:"ds4" (fun c ->
      let system =
        match C.ocaml_config_var c "system" with Some s -> s | None -> ""
      in
      let is_macos = system = "macosx" in
      let base = [ "-O3"; "-ffast-math"; "-g"; "-Wall"; "-Wextra" ] in
      (* Apple clang spells "tune for this machine" -mcpu; GCC/clang on
         Linux/x86 use -march. *)
      let arch = if is_macos then [ "-mcpu=native" ] else [ "-march=native" ] in
      (* Linux needs _GNU_SOURCE for some libc symbols the engine uses, and
         -ffast-math there implies -ffinite-math-only, which the engine's NaN/Inf
         guards rely on NOT being set (upstream adds -fno-finite-math-only). *)
      let linux_extra =
        if is_macos then [] else [ "-D_GNU_SOURCE"; "-fno-finite-math-only" ]
      in
      let core = base @ arch @ [ "-std=c99" ] @ linux_extra in
      (* Objective-C uses ARC instead of -std=c99; only built on macOS. *)
      let objc = base @ arch @ [ "-fobjc-arc" ] in
      C.Flags.write_lines "core_cflags" core;
      C.Flags.write_lines "objc_cflags" objc)
