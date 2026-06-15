(lang dune 3.21)
(using mdx 0.4)
(name deepseek)

(generate_opam_files true)
(implicit_transitive_deps false)

(license ISC)
(authors "Anil Madhavapeddy")
(maintainers "Anil Madhavapeddy <anil@recoil.org>")
(source (tangled anil.recoil.org/ocaml-deepseek))

(package
 (name deepseek)
 (synopsis "Deepseek v4 LLM")
 (tags (org:blacksun deepseek llm))
 (description
  "Library to run Deepseek v4 locally, with a selectable inference backend (Apple Metal or CPU).")
 (depends
  (ocaml (>= 5.2.0))
  (dune-configurator :build)
  (jsont (>= 0.2.0))
  (xdge (>= 1.0.0))
  (eio (>= 1.0))
  (logs (>= 0.7.0))
  (fmt (>= 0.8.7))
  (cmdliner (>= 1.1.0))))
