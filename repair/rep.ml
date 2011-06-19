(* 
 * Program Repair Prototype (v2) 
 *
 * The "representation" interface handles:
 *   -> the program representation (e.g., CIL AST, ASM)
 *   -> gathering and storing fault localization (e.g., weighted path, 
 *      predicates)
 *   -> simple mutation operator building blocks (e.g., delete, 
 *      append, swap) 
 *
 * TODO:
 *  -> "Well-Typed" insert/delete/replace 
 *     (also, no moving "break" out of a loop) 
 *  -> repair templates 
 *  -> predicates
 *  -> asm 
 *
 *)
open Printf
open Utils
open Global
open Pervasives

(*
 * An atom is the smallest unit of our representation: a stmt in CIL,
 * a line of an ASM program, etc.  
 *)
type atom_id = int 
type subatom_id = int 
type stmt = Cil.stmtkind
type test = 
  | Positive of int 
  | Negative of int 
  | Single_Fitness 
type structural_signature = Cdiff.node_id StringMap.t  

(*************************************************************************
 *************************************************************************

                       virtual class REPRESENTATION

   This is the main virtual interface for a program representation (e.g.,
   CIL-AST, Assembly, etc.). 
  
   Most actual representations inherit from "cachingRepresentation", 
   or (better yet) "faultlocRepresentation" below. 

 *************************************************************************
 *************************************************************************)
class virtual (* virtual here means that some methods won't have
               * definitions here, and that they'll have to be filled
               * in when defining a subclass *) 
    ['atom]   (* "atom" is the raw type of the smallest manipulable
               * element. For CIL, this is "Cil.stmtkind"; for 
               * generic assembly code, it could be "string". *)
    representation  (* "representation" is the name of this class/type,
                     * but you'll often see " 'a representation ", where
                     * the 'a means "I don't care what the atom type is".
                     *)
    = object (self : 'self_type)
  method virtual copy : unit -> 'self_type
  method virtual internal_copy : unit -> 'self_type
  method virtual save_binary : ?out_channel:out_channel -> string -> unit (* serialize to a disk file *)
  method virtual load_binary : ?in_channel:in_channel -> string -> unit (* deserialize *) 
  method virtual from_source : string -> unit (* load from a .C or .ASM file, etc. *)
  method virtual output_source : string -> unit (* save to a .C or .ASM file, etc. *)
  method virtual source_name : string list (* is it already saved on the disk as a (set of) .C or .ASM files? *) 
  method virtual sanity_check : unit -> unit 
  method virtual compute_localization : unit ->  unit 
  method virtual compile : ?keep_source:bool -> string -> string -> bool 
  method virtual test_case : test -> (* run a single test case *)
      bool  (* did it pass? *)
    * (float array) 
            (* what was the fitness value? typically 1.0 or 0.0,  but
             * may be arbitrary when single_fitness is used *) 
  method virtual debug_info : unit ->  unit (* print debugging information *) 
  method virtual max_atom : unit -> atom_id (* 1 to N -- INCLUSIVE *) 
  method virtual get_fault_localization : unit -> (atom_id * float) list 
  method virtual get_fix_localization : unit -> (atom_id * float) list 

  (* atomic mutation operators *) 
  method virtual delete : atom_id -> unit 

  (* append and swap find 'what to append' by looking in the code
   * bank (aka stmt_map) -- *not* in the current variant *)
  method virtual append : 
    (* after what *) atom_id -> 
    (* what to append *) atom_id -> unit 

  method virtual append_sources : 
    (* after what *) atom_id -> 
    (* possible append sources *) WeightSet.t 

  method virtual swap : atom_id -> atom_id -> unit 

  method virtual swap_sources : 
    (* swap with what *) atom_id -> 
    (* possible swap sources *) WeightSet.t 

  (* get obtains an atom from the current variant, *not* from the code
     bank *) 
  method virtual get : atom_id -> 'atom

  (* put places an atom into the current variant; the code bank is not
     involved *) 
  method virtual put : atom_id -> 'atom -> unit

  method virtual add_name_note : string -> unit 
  (* add a "history" note to the variant's descriptive name *)

  method virtual name : unit -> string (* a "descriptive" name for this variant *) 

  (* Subatoms.
   * Some representations support a finer-grain than the atom, but still
   * want to perform crossover and mutation at the atom level. For example,
   * C ASTs might have atoms (stmts) and subatoms (expressions). One
   * might want to change expressions, but that complicates crossover
   * (because the number of subatoms may change between variants). So
   * instead we still perform crossover on atoms, but allow sub-atom
   * changes. *) 
  method virtual subatoms : bool (* are they supported? *) 
  method virtual get_subatoms : atom_id -> ('atom list)
  method virtual replace_subatom : atom_id -> subatom_id -> 'atom -> unit 
  method virtual replace_subatom_with_constant : atom_id -> subatom_id -> unit 
  method virtual note_replaced_subatom : atom_id -> subatom_id -> 'atom -> unit

  (* For debugging. *) 
  method virtual atom_to_str : 'atom -> string 

  method virtual hash : unit -> int 
  (* Hashcode. Equal variants must have equal hash codes, but equivalent
     variants need not. By default, this is a hash of the name. *) 

  (* Tree-Structured Comparisons
   *   Mostly for CIL ASTs using the DiffX algorithm. 
   *   Use the "structural_difference" methods to compute the
   *   actual difference. 
   *) 
  method virtual structural_signature : structural_signature

end 


(* 
 * Tree-Structured Differencing. Use the "structural_signature" method of a
 * rep to get the structural signature. You can either inspet the Cdiff
 * edit script directly (it lists tree-structured edits needed to transform
 * rep1 into rep2) or just take the length of that script as the
 * "distance". 
 *)
let structural_difference_edit_script
      (rep1 : structural_signature)
      (rep2 : structural_signature)
      : (Cdiff.edit_action list)
      = 
  let result = ref [] in 
  StringMap.iter (fun name node1 ->
    try
      let node2 = StringMap.find name rep2 in 
      let m = Cdiff.mapping node1 node2 in 
      let s = Cdiff.generate_script 
        (Cdiff.node_of_nid node1) (Cdiff.node_of_nid node2) m in 
      result := s @ !result
    with Not_found -> () 
  ) rep1 ; 
  !result

let structural_difference
      (rep1 : structural_signature)
      (rep2 : structural_signature)
      : int 
      =
  List.length (structural_difference_edit_script rep1 rep2) 

let structural_difference_to_string
      (rep1 : structural_signature)
      (rep2 : structural_signature)
      : string 
      =
  let b = Buffer.create 255 in
  List.iter (fun elt ->
    Printf.bprintf b "%s " (Cdiff.edit_action_to_str elt)
  ) (structural_difference_edit_script rep1 rep2) ;
  Buffer.contents b 


(*
 * This is a list of variables representing global options related to
 * representations. 
 *)
let coverage_sourcename = "coverage" 
let coverage_exename = "coverage" 
let coverage_outname = ref "coverage.path" 
let sanity_filename = "repair.sanity" 
let sanity_exename = "./repair.sanity" 
let always_keep_source = ref false 
let compiler_command = ref ""
let test_command = ref ""
let flatten_path = ref ""
let compiler_name = ref "gcc" 
let compiler_options = ref "" 
let test_script = ref "./test.sh" 
let use_path_files = ref false 
let use_weight_file = ref false 
let use_line_file = ref false 
let label_repair = ref false 
let use_subdirs = ref false 
let use_full_paths = ref false 
let debug_put = ref false 
let port = ref 808
let allow_sanity_fail = ref false 
let no_test_cache = ref false
let no_rep_cache = ref false 
let print_func_lines = ref false 
let use_subatoms = ref false 
let allow_coverage_fail = ref false 

let fault_scheme = ref "path"
let fault_path = ref "coverage.path.neg"
let fault_file = ref ""
let oracle_fault_file = ref ""

let fix_scheme = ref "default"
let fix_path = ref "coverage.path.pos"
let fix_file = ref ""
let oracle_fix_file = ref ""

let prefix = ref "./"
let multi_file = ref false

let _ =
  options := !options @
  [
	"--prefix", Arg.Set_string prefix, "path to original source files";
    "--keep-source", Arg.Set always_keep_source, " keep all source files";
    "--compiler-command", Arg.Set_string compiler_command, "X use X as compiler command";
    "--test-command", Arg.Set_string test_command, "X use X as test command";
    "--test-script", Arg.Set_string test_script, "X use X as test script name";
    "--compiler", Arg.Set_string compiler_name, "X use X as compiler";
    "--compiler-opts", Arg.Set_string compiler_options, "X use X as options";
    "--label-repair", Arg.Set label_repair, " indicate repair locations";
    "--use-subdirs", Arg.Set use_subdirs, " use one subdirectory per variant";
    "--use-full-paths", Arg.Set use_full_paths, " use full pathnames";
    "--flatten-path", Arg.Set_string flatten_path, "X flatten weighted path (sum/min/max)";
    "--debug-put", Arg.Set debug_put, " note each #put in a variant's name" ;
    "--allow-sanity-fail", Arg.Set allow_sanity_fail, " allow sanity checks to fail";
    "--print-func-lines", Arg.Set print_func_lines, " print start/end line numbers of all functions" ;
    "--use-subatoms", Arg.Set use_subatoms, " use subatoms (expression-level mutation)" ;
    "--allow-coverage-fail", Arg.Set allow_coverage_fail, " allow coverage to fail its test cases" ;

	"--fault-scheme", Arg.Set_string fault_scheme, " How to do fault localization.  Options: path, uniform, line, weight, oracle, default. Default: path";
	"--fault-path", Arg.Set_string fault_path, "Negative path file, for path-based fault or fix localization.  Default: coverage.path.neg";
	"--fault-file", Arg.Set_string fault_file, " Fault localization file.  e.g., Lines/weights if scheme is lines/weights.";
	"--fault-oracle", Arg.Set_string oracle_fault_file, " Source code for the oracle fault information.";

	"--fix-scheme", Arg.Set_string fix_scheme, " How to do fix localization.  Options: path, uniform, line, weight, oracle, default (whatever Wes was doing before). Default: path";
	"--fix-path", Arg.Set_string fix_path, "Positive path file, for path-based fault or fix localization. Default: coverage.path.pos";
	"--fix-file", Arg.Set_string fix_file, " Fix localization file.  Default: coverage.path.pos";
	"--fix-oracle", Arg.Set_string oracle_fix_file, " source code for the oracle fix information";

	"--coverage-out", Arg.Set_string coverage_outname, " where to put the path info when instrumenting source code for coverage.  Default: ./coverage.path"
  ] 

(*
 * Utility functions for test cases. 
 *)
let test_name t = match t with
  | Positive x -> sprintf "p%d" x
  | Negative x -> sprintf "n%d" x
  | Single_Fitness -> "s" 

let change_port () = (* network tests need a fresh port each time *)
  port := (!port + 1) ;
  if !port > 1600 then 
    port := !port - 800 

(*
 * Persistent caching for test case evaluations. 
 *)
let test_cache = ref 
  ((Hashtbl.create 255) : (Digest.t list, (test,(bool*(float array))) Hashtbl.t) Hashtbl.t)
let test_cache_query digest test = 
  if Hashtbl.mem !test_cache digest then begin
    let second_ht = Hashtbl.find !test_cache digest in
    try
      let res = Hashtbl.find second_ht test in
      Stats2.time "test_cache hit" (fun () -> Some(res)) () 
    with _ -> None 
  end else None 
let test_cache_add digest test result =
  let second_ht = 
    try
      Hashtbl.find !test_cache digest 
    with _ -> Hashtbl.create 7 
  in
  Hashtbl.replace second_ht test result ;
  Hashtbl.replace !test_cache digest second_ht 
let test_cache_version = 3
let test_cache_save () = 
  let fout = open_out_bin "repair.cache" in 
  Marshal.to_channel fout test_cache_version [] ; 
  Marshal.to_channel fout (!test_cache) [] ; 
  close_out fout 
let test_cache_load () = 
  try 
    let fout = open_in_bin "repair.cache" in 
    let v = Marshal.from_channel fout in  
    if v <> test_cache_version then begin
      debug "repair.cache: file format %d expected, %d found (skipping)" 
        test_cache_version v ; 
      close_in fout ; 
      raise Not_found 
    end ;
    test_cache := Marshal.from_channel fout ; 
    close_in fout 
  with _ -> () 

(* 
 * We track the number of unique test evaluations we've had to
 * do on this run, ignoring of the persistent cache.
 *)
let tested = (Hashtbl.create 4095 : ((Digest.t list * test), unit) Hashtbl.t)
let num_test_evals_ignore_cache () = 
  let result = ref 0 in
  Hashtbl.iter (fun _ _ -> incr result) tested ;
  !result

let compile_failures = ref 0 
let test_counter = ref 0 
exception Test_Result of (bool * (float array))

let add_subdir str = 
  let result = 
    if not !use_subdirs then
      "." 
    else begin
      let dirname = match str with
      | None -> sprintf "%06d" !test_counter
      | Some(specified) -> specified 
      in
      (try Unix.mkdir dirname 0o755 with _ -> ()) ;
      dirname 
    end 
  in
  if !use_full_paths then
    Filename.concat (Unix.getcwd ()) result
  else
    result 

(*************************************************************************
 *************************************************************************

                    virtual class CACHINGREPRESENTATION

   This interface for a program representaton handles the caching
   of compilations and test case results for you, as well as 
   dealing with some sanity checks. 
  
 *************************************************************************
 *************************************************************************)
class virtual ['atom] cachingRepresentation = object (self) 
  inherit ['atom] representation 

  (***********************************
   * Methods that must be provided
   * by a subclass. 
   ***********************************)

  method virtual internal_test_case : 
    string -> (* exename *) 
    string -> (* source name *) 
    test -> (* test case *) 
    (bool * (* passed? *) 
     float array) (* real-valued fitness, or 1.0/0.0 *) 

  method virtual get_compiler_command : unit -> string 

  method virtual instrument_fault_localization : 
    string -> (* coverage source name *) 
    string -> (* coverage exe name *) 
    string -> (* coverage data out name *) 
    unit 

  (***********************************
   * State Variables
   ***********************************)
  val already_sourced = ref None 
  val already_compiled = ref None
  val source_file = ref "" 
  val history = ref [] 

  (***********************************
   * Methods
   ***********************************)
  method source_name = begin
    match !already_sourced with
    | Some(source_names,digest) -> source_names
    | None -> [] 
  end 

  method get_test_command () = 
    "__TEST_SCRIPT__ __EXE_NAME__ __TEST_NAME__ __PORT__ __SOURCE_NAME__ __FITNESS_FILE__ >& /dev/null" 

  method copy () = 
    ({< history = ref !history ; 
        already_sourced = ref !already_sourced ; 
        already_compiled = ref !already_compiled ; 
      >})

  (* indicate that cached information based on our AST structure
   * is no longer valid *) 
  method updated () = 
    already_compiled := None ;
    already_sourced := None ; 
    () 

  (* Compile this variant to an executable on disk. *)
  method compile ?(keep_source=false) source_name exe_name = begin
    let base_command = 
      match !compiler_command with 
      | "" -> self#get_compiler_command () 
      |  x -> x
    in
    let cmd = Global.replace_in_string base_command 
      [ 
        "__COMPILER_NAME__", !compiler_name ;
        "__EXE_NAME__", exe_name ;
        "__SOURCE_NAME__", source_name ;
        "__COMPILER_OPTIONS__", !compiler_options ;
      ] 
    in 
    let result = (match Stats2.time "compile" Unix.system cmd with
    | Unix.WEXITED(0) -> 
        already_compiled := Some(exe_name,source_name) ; 
        true
    | _ -> 
        already_compiled := Some("",source_name) ; 
        debug "\t%s %s fails to compile\n" source_name (self#name ()) ; 
        incr compile_failures ;
        false 
    ) in
    if not (keep_source || !always_keep_source) then begin
	  let files = Str.split space_regexp source_name in 
		liter Unix.unlink files;
    end ;
    result
  end 


  (* An internal method for the raw running of a test case.
   * This does the bare bones work: execute the program
   * on the test case. No caching at this level. *)
  method internal_test_case exe_name source_name test = begin
    let port_arg = Printf.sprintf "%d" !port in
    change_port () ; 
    let base_command = 
      match !test_command with 
      | "" -> self#get_test_command () 
      |  x -> x
    in
    let fitness_file = exe_name ^ ".fitness" in 
    let cmd = Global.replace_in_string base_command 
      [ 
        "__TEST_SCRIPT__", !test_script ;
        "__EXE_NAME__", exe_name ;
        "__TEST_NAME__", (test_name test) ;
        "__SOURCE_NAME__", (source_name) ;
        "__FITNESS_FILE__", (fitness_file) ;
        "__PORT__", port_arg ;
      ] 
    in 
    let real_valued = ref [| 0. |] in 
    let result = 
      match Stats2.time "test" Unix.system cmd with
      | Unix.WEXITED(0) -> (real_valued := [| 1.0 |]) ; true 
      | _ -> (real_valued := [| 0.0 |]) ; false
    in 
    (try
      let str = file_to_string fitness_file in 
      let parts = Str.split (Str.regexp "[, \t\r\n]+") str in 
      let values = List.map (fun v ->
        try 
          float_of_string v 
        with _ -> begin 
          debug "%s: invalid\n%S\nin\n%S" 
            fitness_file v str ;
          0.0
        end
      ) parts in
      (*
      debug "internal_test_case: %s" (self#name ()) ; 
      List.iter (fun x ->
        debug " %g" x
      ) values ;
      debug "\n" ; 
      *) 
      if values <> [] then 
        real_valued := Array.of_list values 
    with _ -> ()) ;
    (if not !always_keep_source then
      (try Unix.unlink fitness_file with _ -> ())) ; 
    (* return the results *) 
    result, !real_valued
  end 

  (* Perform various sanity checks. Currently we check to
   * ensure that that original program passes all positive
   * tests and fails all negative tests. *) 
  method sanity_check () = begin
    debug "cachingRepresentation: sanity checking begins\n" ; 
    let subdir = add_subdir (Some("sanity")) in 
    let sanity_filename = Filename.concat subdir (sanity_filename
      ^ "." ^ !Global.extension) in 
    let sanity_exename = Filename.concat subdir sanity_exename in 
      self#output_source sanity_filename ; 
    let c = self#compile ~keep_source:true sanity_filename sanity_exename in
    if not c then begin
      debug "cachingRepresentation: %s: does not compile\n" sanity_filename ;
      if not !allow_sanity_fail then 
        exit 1 
    end ; 
    for i = 1 to !pos_tests do
      let r, g = self#internal_test_case sanity_exename sanity_filename 
        (Positive i) in
      debug "\tp%d: %b (%s)\n" i r (float_array_to_str g) ;
      assert(!allow_sanity_fail || r) ; (* Yam, if you need this to be
      commented out, do it on your local copy and/or add a new flag *) 
    done ;
    for i = 1 to !neg_tests do
      let r, g = self#internal_test_case sanity_exename sanity_filename 
        (Negative i) in
      debug "\tn%d: %b (%s)\n" i r (float_array_to_str g) ;
      assert(!allow_sanity_fail || (not r)) ; 
    done ;
    debug "cachingRepresentation: sanity checking passed\n" ; 
  end 

  (* This is our public interface for running a single test case.
   * It checks in the cache, compiles this to an EXE if  
   * needed, and runs the EXE on the test case. *) 
  method test_case test = try begin
    let try_cache () = 
      (* first, maybe we'll get lucky with the persistent cache *) 
      (match !already_sourced with
      | None -> ()
      | Some(filename,digest) -> begin 
        match test_cache_query digest test with
        | Some(x,f) -> raise (Test_Result (x,f))
        | _ -> ()
        end  
      )  
    in 
    try_cache () ; 
    (* second, maybe we've already compiled it *) 
    let exe_name, source_name, worked = match !already_compiled with
    | None -> (* never compiled before, so compile it now *) 
      let subdir = add_subdir None in 
      let source_name = Filename.concat subdir
        (sprintf "%06d.%s" !test_counter !Global.extension) in  
      let exe_name = Filename.concat subdir
        (sprintf "%06d" !test_counter) in  
      incr test_counter ; 
      if !test_counter mod 10 = 0 && not !no_test_cache then begin
        test_cache_save () ;
      end ; 
      self#output_source source_name ; 
      try_cache () ; 
      if not (self#compile source_name exe_name) then 
        exe_name,source_name,false
      else
        exe_name,source_name,true

    | Some("",source) -> "", source, false (* it failed to compile before *) 
    | Some(exe,source) -> exe, source, true (* compiled successfully before *) 
    in
    let result = 
      if worked then begin 
        (* actually run the program on the test input *) 
        self#internal_test_case exe_name source_name test 
      end else false, [| 0.0 |] 
    in 
    (* record result for posterity in the cache *) 
    (match !already_sourced with
    | None -> ()
    | Some(filename,digest) -> test_cache_add digest test result
    ) ; 
    raise (Test_Result(result))

  end with

    Test_Result(x) -> (* additional bookkeeping information *) 
    (match !already_sourced with
    | None -> ()
    | Some(filename,digest) -> Hashtbl.replace tested (digest,test) () 
    ) ;
    x


  (* give a "descriptive" name for this variant. For most, the name is
   * based on the atomic mutations applied in order. Those are stored
   * in the "history" list. *) 
  method name () = 
    if !history = [] then "original"
    else begin 
      let b = Buffer.create 40 in
      ignore (List.rev_map (fun s ->
        Buffer.add_string b s ; () 
      ) !history) ;
      Buffer.contents b 
    end 

  method hash () = 
    Hashtbl.hash self#name 

  method add_name_note str =
    history := str :: !history 

  method delete stmt_id = 
    self#updated () ; 
    history := (sprintf "d(%d)" stmt_id) :: !history 

  method append x y = 
    self#updated () ; 
    history := (sprintf "a(%d,%d)" x y) :: !history 

  method append_sources x = 
    let result = ref WeightSet.empty in 
    for i = 1 to self#max_atom () do
      result := WeightSet.add (i,1.0) !result 
    done ;
    !result 

  method swap_sources x = 
    let result = ref WeightSet.empty in 
    for i = 1 to self#max_atom () do
      result := WeightSet.add (i,1.0) !result 
    done ;
    !result 
    

  method swap x y =
    self#updated () ; 
    history := (sprintf "s(%d,%d)" x y) :: !history 

  method put x y = 
    self#updated () ;
    (if !debug_put then 
      history := (sprintf "p(%d)" (x)) :: !history ;
    ) 

  method note_replaced_subatom x y atom =  
    self#updated () ;
    history := (sprintf "e(%d,%d,%s)" x y (self#atom_to_str atom)) :: !history 

end 


(*
 * We may want to turn
 *  1, 5
 *  2, 3
 *  2, 3
 *  3, 10
 *
 * into
 *  1, 5
 *  2, 6
 *  3, 10 
 *)
let flatten_weighted_path wp = 
  let seen = Hashtbl.create 255 in
  let id_list = List.fold_left (fun acc (sid,v) ->
    try
      let v_so_far = Hashtbl.find seen sid in
      let v_new = match !flatten_path with
      | "min" -> min v_so_far v  
      | "max" -> max v_so_far v
      | "sum" | _ -> v_so_far +. v
      in 
      Hashtbl.replace seen sid v_new ;
      acc 
    with Not_found ->
      sid :: acc) [] wp in  
  let id_list = List.rev id_list in 
  List.map (fun sid ->
    sid, Hashtbl.find seen sid
  ) id_list 

let faultlocRep_version = "2" 

(*************************************************************************
 *************************************************************************

                   virtual class FAULTLOCREPRESENTATION

   This interface for a program representaton handles various
   simple fault localization (i.e., "weighted path") approaches
   for you. 
   
   This is currently a good class to inherit your representation
   from. 
  
 *************************************************************************
 *************************************************************************)
class virtual ['atom] faultlocRepresentation = object (self) 
  inherit ['atom] cachingRepresentation as super 

  (***********************************
   * State Variables
   ***********************************)
  val weighted_path = ref ([] : (atom_id * float) list) 
  val fix_weights = ref ([] : (atom_id * float) list)

  (***********************************
   * No Subatoms 
   * (subclasses can override)
   ***********************************)
  method subatoms = false
  method get_subatoms = failwith "get_subatoms" 
  method replace_subatom = failwith "replace_subatom" 
  method replace_subatom_with_constant = failwith "replace_subatom_with_constant" 

  (***********************************
   * Methods
   ***********************************)
  method virtual atom_id_of_source_line : string -> int -> atom_id 

  method save_binary ?out_channel (filename : string) = begin
    let fout = 
      match out_channel with
      | Some(v) -> v
      | None -> assert(false); 
    in 
    Marshal.to_channel fout (faultlocRep_version) [] ; 
    Marshal.to_channel fout (!weighted_path) [] ;
    Marshal.to_channel fout (!fix_weights) [] ;
    debug "faultlocRep: %s: saved\n" filename ; 
  end 

  method load_binary ?in_channel (filename : string) = begin
    let fin = 
      match in_channel with
      | Some(v) -> v
      | None -> assert(false); 
    in 
    let version = Marshal.from_channel fin in
    if version <> faultlocRep_version then begin
      debug "faultlocRep: %s has old version\n" filename ;
      failwith "version mismatch" 
    end ;
    weighted_path := Marshal.from_channel fin ; 
    fix_weights := Marshal.from_channel fin ; 
    debug "faultlocRep: %s: loaded\n" filename ; 
  end 

  (* Compute the fault localization information. For now, this is 
   * weighted path localization based on statement coverage. *) 

  method compute_localization () = 
	debug "in compute localization, fault_scheme: %s, fix_scheme: %s\n" !fault_scheme !fix_scheme;
	(* check legality *)
	(match !fault_scheme with
	  "path" | "uniform" | "line" | "weight" | "oracle" -> ()
	| "default" -> fault_scheme := "path"
	| _ -> debug "WARNING: unrecognized fault localization scheme: %s, defaulting to uniform\n" !fault_scheme; fault_scheme := "uniform");
	(match !fix_scheme with
	  "path" | "uniform" | "line" | "weight" | "oracle" | "default" -> ()
	| _ -> debug "WARNING: unrecognized fix localization scheme: %s, defaulting to default\n" !fix_scheme; fix_scheme := "default");

	let fix_weights_to_lst ht = 
      let res = ref [] in 
		Hashtbl.iter (fun  stmt_id weight  ->
		  res := (stmt_id,weight) :: !res 
		) ht;
		!res
	in
	let uniform () = 
	  let res = ref [] in 
	  for i = 1 to self#max_atom () do
		res := (i, 1.0) :: !res
	  done; !res
	in
	let path_files () = 
	  let weighted_path = ref [] in 
	  let fix_weights = hcreate 10 in
		for i = 1 to self#max_atom () do
		  Hashtbl.replace fix_weights i 0.1 ;
		done ;
		let neg_ht = Hashtbl.create 255 in 
		let pos_ht = Hashtbl.create 255 in 
		  iter_lines !fix_path
			(fun line ->
			  Hashtbl.replace pos_ht line () ;
			  Hashtbl.replace fix_weights (int_of_string line) 0.5);
		  iter_lines !fault_path
			(fun line ->
			  if not (Hashtbl.mem neg_ht line) then
				begin 
				 (* a statement only on the negative path gets weight 1.0 ;
				  * if it is also on the positive path, its weight is 0.1 *) 
				  let weight = if Hashtbl.mem pos_ht line then 0.1 else 1.0 in 
					weighted_path := (int_of_string line, weight) :: !weighted_path ;
					Hashtbl.replace neg_ht line () ; 
					Hashtbl.replace fix_weights (int_of_string line) 0.5 ; 
				end);
		  !weighted_path,fix_weights
	in
	let line_or_weight_file fname scheme =
	  (* Give a list of "file,stmtid,weight" tuples. You can separate with
	   * commas and/or whitespace. If you leave off the weight,
	   * we assume 1.0. You can leave off the file as well. *) 
	  let regexp = Str.regexp "[ ,\t]" in 
	  let fix_weights = hcreate 10 in 
	  let weighted_path = ref [] in
		for i = 1 to self#max_atom () do
		  Hashtbl.replace fix_weights i 0.1 ;
		done ;
		iter_lines fname
		  (fun line ->
			let s, w, file = 
			  match (Str.split regexp line) with
			  | [stmt] -> (int_of_string stmt), 1.0, ""
			  | [stmt ; weight] -> (int_of_string stmt), 
                (float_of_string weight), ""
			  | [file ; stmt ; weight] -> (int_of_string stmt), 
                (float_of_string weight), file
			  | _ -> debug "ERROR: %s: malformed line:\n%s\n" !fault_file line;
				failwith "malformed input"
			in 
			let s = if scheme = "line" then self#atom_id_of_source_line file s else s
			in
			 (* this assert used to be an if; is there a good reason for that? *)
			  assert(s >= 1 && s <= self#max_atom());
			  weighted_path := (s,w) :: !weighted_path ;
			  Hashtbl.replace fix_weights s 0.5
		  );
		!weighted_path,fix_weights
	in
	  debug "rep: compute fault and fix localization\n" ; 
	  try
		if (!fault_scheme = "path" || !fix_scheme = "path") then begin
		  if (not ((Sys.file_exists !fault_path) && (Sys.file_exists !fix_path))) then begin
			(* instrument for coverage if necessary *)
 			let subdir = add_subdir (Some("coverage")) in 
			let coverage_sourcename = Filename.concat subdir 
			  (coverage_sourcename ^ "." ^ !Global.extension) in 
			let coverage_exename = Filename.concat subdir coverage_exename in 
			let coverage_outname = Filename.concat subdir !coverage_outname in 
			  self#instrument_fault_localization 
				coverage_sourcename coverage_exename coverage_outname ;
		  end;
		  let wp, fw = path_files () in
			if !fault_scheme = "path" then weighted_path := wp;
			if !fix_scheme = "path" || !fix_scheme = "default" then fix_weights := fix_weights_to_lst fw
		end;
		if !fault_scheme = "uniform" then weighted_path := uniform ()
		else if !fault_scheme = "line" || !fault_scheme = "weight" then begin
		  let wp,fw = line_or_weight_file !fault_file !fault_scheme in 
			weighted_path := wp;
			if !fix_scheme = "default" then fix_weights := fix_weights_to_lst fw;
		end else if !fault_scheme = "oracle" then begin
		end;
		if !fix_scheme = "uniform" then fix_weights := uniform ()
		else if !fix_scheme = "line" || !fix_scheme = "weight" then begin
		  let wp,_ = line_or_weight_file !fix_file !fix_scheme in 
			fix_weights := wp
		end else if !fix_scheme = "oracle" then begin
		  
		end
	  with e -> begin
		debug "faultlocRep: No Fault or Fix Localization: %s\n" (Printexc.to_string e) ; 
		weighted_path := uniform();
		fix_weights := uniform();
	  end ;
		if !flatten_path <> "" then 
		  weighted_path := flatten_weighted_path !weighted_path ;
		weighted_path := List.rev !weighted_path ;

  method get_fault_localization () = !weighted_path 

  method get_fix_localization () = !fix_weights

end 

let global_filetypes = ref ([] : (string * (unit -> unit)) list)

