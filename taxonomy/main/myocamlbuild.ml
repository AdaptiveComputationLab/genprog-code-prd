(* ocamlbuild plugin for building Batteries.  
 * Copyright (C) 2010 Michael Ekstrand
 * 
 * Portions (hopefully trivial) from build/myocamlbuild.ml and the
 * Gallium wiki. *)

open Ocamlbuild_plugin

let ocamlfind x = S[A"ocamlfind"; A x]

let packs = String.concat "," ["batteries"]

let _ = dispatch begin function
  | Before_options ->
      (* Set up to use ocamlfind *)
      Options.ocamlc     := ocamlfind "ocamlc";
      Options.ocamlopt   := ocamlfind "ocamlopt";
      Options.ocamldep   := ocamlfind "ocamldep";
      Options.ocamldoc   := ocamlfind "ocamldoc";
      Options.ocamlmktop := ocamlfind "ocamlmktop"
  | Before_rules -> ()
  | After_rules ->
      (* When one links an OCaml program, one should use -linkpkg *)
      flag ["ocaml"; "link"; "program"] & A"-linkpkg";
	flag ["ocaml"; "link"] & S [A"-cclib" ; A "-lz3"];
	flag ["ocaml"; "link"] & S [A"-cclib" ; A "-lz3stubs"];
	flag ["ocaml"; "link"] & S [A"/usr/lib/ocaml/libcamlidl.a"];

      flag ["ocaml"; "compile"] & S[A"-package"; A packs];
      flag ["ocaml"; "ocamldep"] & S[A"-package"; A packs];
      flag ["ocaml"; "doc"] & S[A"-package"; A packs];
      flag ["ocaml"; "link"] & S[A"-package"; A packs];
      flag ["ocaml"; "infer_interface"] & S[A"-package"; A packs];

      flag ["ocaml"; "infer_interface"; "pkg_oUnit"] & S[A"-package"; A"oUnit"];
      flag ["ocaml"; "ocamldep"; "pkg_oUnit"] & S[A"-package"; A"oUnit"];
      flag ["ocaml"; "compile"; "pkg_oUnit"] & S[A"-package"; A"oUnit"];
      flag ["ocaml"; "link"; "pkg_oUnit"] & S[A"-package"; A"oUnit"];

      (* DON'T USE TAG 'thread', USE 'threads' 
	 for compatibility with ocamlbuild *)
      flag ["ocaml"; "compile"; "threads"] & A"-thread";
      flag ["ocaml"; "link"; "threads"] & A"-thread";
      flag ["ocaml"; "doc"; "threads"] & S[A"-I"; A "+threads"];

      flag ["ocaml"; "doc"] & S[A"-hide-warnings"; A"-sort"];
      
      flag ["ocaml"; "compile"; "camlp4rf"] &
        S[A"-package"; A"camlp4.lib"; A"-pp"; A"camlp4rf"];
      flag ["ocaml"; "ocamldep"; "camlp4rf"] &
        S[A"-package"; A"camlp4.lib"; A"-pp"; A"camlp4rf"];

      flag ["ocaml"; "compile"; "camlp4of"] &
        S[A"-package"; A"camlp4.lib"; A"-pp"; A"camlp4of"];
      flag ["ocaml"; "ocamldep"; "camlp4of"] &
        S[A"-package"; A"camlp4.lib"; A"-pp"; A"camlp4of"];
  | _ -> ()
end