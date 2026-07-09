(lang dune 3.0)

(name ocaml-ai-agent)

(generate_opam_files true)
(implicit_transitive_deps false)

(license ISC)
(authors "Anil Madhavapeddy (upstream ocaml-deepseek)" "kengirie")
(maintainers "kengirie")
(source
 (github kengirie/ocaml-ai-agent))

(package
 (name ocaml-ai-agent)
 (synopsis "Capability-confined tools for LLM agents in OCaml")
 (description
  "A small tool-using agent for the Anthropic Claude API whose tools are confined by Eio capabilities and described by a typed schema combinator. Cloud-only: no model weights and no native code.")
 (depends
  (ocaml (>= 5.2.0))
  (eio (>= 1.0))
  (piaf (>= 0.2.0))
  (yojson (>= 2.0.0))
  (uri (>= 4.0.0))
  (cmdliner (>= 1.1.0))
  (fmt (>= 0.8.7))))
