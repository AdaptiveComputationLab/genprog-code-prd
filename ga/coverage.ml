(* Transform a C program to print out all of the statements it visits
 * to stderr. Basically, this computes statement coverage a la standard
 * testing. 
 *
 * This is used as a first step in Weimer's Genetic Programming approach to
 * evolving a program variant that adheres to some testcases. 
 *
 * You apply 'coverage' to a single C file (use CIL to combine a big
 * project into a single C file) -- say, foo.c. This produces:
 *
 * foo.ast  -- a serialized CIL AST of the *original* program
 *
 * foo.ht   -- a hashtable mapping from numbers to
 *             'statements' in the *original* foo.c
 *
 * 'stdout' -- an *instrumented* version of foo.c that prints out
 *             each 'statement' reached at run-time into
 *             the file foo.path
 *
 * If you pass --loc to coverage, it also produces file_loc.ht, 
 * a hashtable that maps statement numbers to location information.
 * Typical usage: 
 *
 *   ./coverage foo_comb.c > foo_coverage.c 
 * 
 * if --preds file.txt argument is passed, coverage will modify the program
 * such that the functions listed in file.txt are put in their own Instr and
 * will then skip them in printing statement numbers. This is to be used when
 * including predicate instrumentation function calls in your program;
 * we don't want to move the instrumentation calls because they are tied to
 * program locations. 
 * 
 * This is not the right approach; we should group the predicate instrumentation
 * with the statements they instrument.
 *
 * (when this happens, does the predicate know the location has changed?)
 * 
 * NTS: we need to deal with printing out output even when the program crashes.
 * 
 * --preds will also skip included header functions.
 *) 
open Printf
open Cil

let loc_info = ref false 
let preds = ref false
let loc_debug = ref false

let fprintf_va = makeVarinfo true "fprintf" (TVoid [])
let fopen_va = makeVarinfo true "fopen" (TVoid [])
let fflush_va = makeVarinfo true "fflush" (TVoid [])
let stderr_va = makeVarinfo true "_coverage_fout" (TPtr(TVoid [], []))
let fprintf = Lval((Var fprintf_va), NoOffset)
let fopen = Lval((Var fopen_va), NoOffset)
let fflush = Lval((Var fflush_va), NoOffset)
let stderr = Lval((Var stderr_va), NoOffset)
let counter = ref 1 

let massive_hash_table = Hashtbl.create 4096  
let location_hash_table = Hashtbl.create 4096

let claire_str = Str.regexp_string "claire"
(* 
 * Here is the list of CIL statementkinds that we consider as
 * possible-to-be-modified
 * (i.e., nodes in the AST that we may mutate/crossover via GP later). 
 *)

let can_trace s = 
  if (List.length s.labels > 0) && 
	(List.fold_left 
	   (fun accum -> 
		  fun lab ->
			match lab with 
				Label(lab,_,_) -> Str.string_match claire_str lab 0
			  | _ -> accum) false s.labels) then
	  false else
		begin
	match s.skind with
	  | Instr _
	  | Return _  
	  | If _ 
	  | Loop _ 
		-> true
		  
	  | Goto _ 
	  | Break _ 
	  | Continue _ 
	  | Switch _ 
	  | Block _ 
	  | TryFinally _ 
	  | TryExcept _ 
		-> false
  end

let get_next_count () = 
  let count = !counter in 
  incr counter ;
  count 

(* This visitor replaces instructions that contain lists that contains a call to
 * a predicate instrumentation function (or any function; I think it's 
 * user-specified) by 3 instructions - one is the instructions before the
 * call in the original instruction list, one is an instruction containing
 * the call to the function in question, and the last is the instructions
 * after the call in the original instruction list *)
 
(* does this instruction list contain a call to an interesting function? *)
(* FIXME: what if there's more than one?*)
let contains_funcall lst = false 

(* return the position of a call to an interesting function in this list *)

let find_funcall lst = 0

(* TEST ME *)
exception SubException of int * int * int

let rec sub lst starti endi curri = 
  match lst with
      l :: ls ->
	if curri >= starti && curri < endi then 
	  l :: (sub ls starti endi (curri+1))
	else []
    | [] -> raise (SubException(starti,endi,curri))

(* should be called before numbering *)

class funVisitor = object
  inherit nopCilVisitor
  method vstmt s = 
    ChangeDoChildrenPost
      (s, 
       (fun s ->
	match s.skind with
	  | Instr(ilist) ->
	      if (contains_funcall ilist) then begin
		let funcall_pos = find_funcall ilist in
		let first_stmt = {labels=s.labels;
				  skind=Instr(sub ilist 0 (funcall_pos - 1) 0);
				 sid=0;
				 succs=[];
				 preds=[];} in
		let funcall_stmt = {labels=[];
				    skind=Instr((List.nth ilist funcall_pos) :: []);
				   sid=0;
				   succs=[];
				   preds=[];} in
		let last_stmt = {labels=s.labels;
				 skind=Instr(sub ilist (funcall_pos + 1) (List.length ilist) 0);
				 sid=0;
				 succs=[];
				 preds=[];} in
		  {s with skind=Block({battrs=[]; bstmts=(first_stmt::funcall_stmt::last_stmt::[])})}
	      end
	      else s
	  | _ -> s
       ))
end

let copy (x : 'a) = 
  let str = Marshal.to_string x [] in
  (Marshal.from_string str 0 : 'a) 
  (* Cil.copyFunction does not preserve stmt ids! Don't use it! *) 

(* This visitor walks over the C program AST and builds the hashtable that
 * maps integers to statements. *) 

class numToZeroVisitor = object
  inherit nopCilVisitor
  method vstmt s = 
    s.sid <- 0 ; DoChildren
end 

let my_zero = new numToZeroVisitor

class numVisitor = object
  inherit nopCilVisitor
  method vblock b = 
    ChangeDoChildrenPost(b,(fun b ->
      List.iter (fun b -> 
        if can_trace b then begin
          let count = get_next_count () in 
          b.sid <- count ;
	    let bcopy = copy b in
	    let bcopy = visitCilStmt my_zero bcopy in
	      Hashtbl.add massive_hash_table count bcopy.skind
        end else begin
		  let labels = 
			List.filter
			  (fun lab ->
				 match lab with
					 Label(lab,_,_) -> not (Str.string_match claire_str lab 0)
				   | _ -> true) b.labels in
			b.labels <- labels ;
			b.sid <- 0; 
        end ;
      ) b.bstmts ; 
      b
    ) )
end 

(* This visitor walks over the C program AST and modifies it so that each
 * statment is preceeded by a 'printf' that writes that statement's number
 * to the .path file at run-time. *) 
class covVisitor = object
  inherit nopCilVisitor
  method vblock b = 
    ChangeDoChildrenPost(b,(fun b ->
      let result = List.map (fun stmt -> 
        if stmt.sid > 0 then begin
          let str = 
	    if !loc_debug then begin
	      let loc = Hashtbl.find location_hash_table stmt.sid in
		Printf.sprintf "%d,%s,%d,%d\n" stmt.sid loc.file loc.line loc.byte
	    end else
	      Printf.sprintf "%d\n" stmt.sid 
	  in
          let str_exp = Const(CStr(str)) in 
          let instr = Call(None,fprintf,[stderr; str_exp],!currentLoc) in 
          let instr2 = Call(None,fflush,[stderr],!currentLoc) in 
          let skind = Instr([instr;instr2]) in
          let newstmt = mkStmt skind in 
          [ newstmt ; stmt ] 
        end else [stmt] 
      ) b.bstmts in 
      { b with bstmts = List.flatten result } 
    ) )
end 

let my_cv = new covVisitor 
let my_num = new numVisitor 

let main () = begin
  let usageMsg = "Prototype No-Specification Bug-Fixer\n" in 
  let do_cfg = ref false in 
  let filenames = ref [] in 

  let argDescr = [
    "--calls", Arg.Set do_cfg, " convert calls to end basic blocks";
    "--loc", Arg.Set loc_info, " include location info in path printout";
  ] in 
  let handleArg str = filenames := str :: !filenames in 
  Arg.parse (Arg.align argDescr) handleArg usageMsg ; 

  Cil.initCIL () ; 
  List.iter (fun arg -> 
    begin
      let file = Frontc.parse arg () in 
      if !do_cfg then begin
        Partial.calls_end_basic_blocks file
      end ; 
	Cfg.computeFileCFG file;

      visitCilFileSameGlobals my_num file ; 
      let ast = arg ^ ".ast" in 
      let fout = open_out_bin ast in 
      Marshal.to_channel fout (file) [] ;
      close_out fout ; 

      visitCilFileSameGlobals my_cv file ; 

      let new_global = GVarDecl(stderr_va,!currentLoc) in 
      file.globals <- new_global :: file.globals ; 

      let fd = Cil.getGlobInit file in 
      let lhs = (Var(stderr_va),NoOffset) in 
      let data_str = arg ^ ".path" in 
      let str_exp = Const(CStr(data_str)) in 
      let str_exp2 = Const(CStr("wb")) in 
      let instr = Call((Some(lhs)),fopen,[str_exp;str_exp2],!currentLoc) in 
      let new_stmt = Cil.mkStmt (Instr[instr]) in 
      fd.sbody.bstmts <- new_stmt :: fd.sbody.bstmts ; 
      iterGlobals file (fun glob ->
        dumpGlobal defaultCilPrinter stdout glob ;
      ) ; 
      let ht = arg ^ ".ht" in 
      let loc_ht = arg ^ "_loc.ht" in
      let fout = open_out_bin ht in 
      Marshal.to_channel fout (!counter,massive_hash_table) [] ;
      close_out fout ; 
      let fout = open_out_bin loc_ht in 
	Marshal.to_channel fout (location_hash_table) [] ;
	close_out fout ;
    end 
  ) !filenames ; 

end ;;

main () ;;