(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2019       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Pp
open CErrors
open Util
open Names
open Constr
open Context
open Term
open EConstr
open Vars
open Inductiveops
open Glob_term
open Glob_ops
open Termops
open Namegen
open Libnames
open Globnames
open Mod_subst
open Context.Named.Declaration
open Ltac_pretype

type detyping_flags = {
  flg_lax : bool;
  flg_isgoal : bool;
}

module Avoid :
sig
  type t
  val make : fast:bool -> Id.Set.t -> t
  val compute_name : Evd.evar_map -> let_in:bool -> pattern:bool ->
    detyping_flags -> t -> Name.t list * 'a -> Name.t ->
    EConstr.constr -> Name.t * t
  val next_name_away : detyping_flags -> Name.t -> t -> Id.t * t
end =
struct

open Nameops

type t =
| Nice of Id.Set.t
| Fast of Subscript.t Id.Map.t
  (** Overapproximation of the set of names to avoid. If [(id ↦ s) ∈ m] then for
      all subscript [s'] smaller than [s], [add_subscript id s'] needs to be
      avoided. *)

let make ~fast ids =
  if fast then
    let fold id accu =
      let id, ss = get_subscript id in
      let old_ss = try Id.Map.find id accu with Not_found -> Subscript.zero in
      if Subscript.compare ss old_ss <= 0 then accu else Id.Map.add id ss accu
    in
    let avoid = Id.Set.fold fold ids Id.Map.empty in
    Fast avoid
  else Nice ids

let fresh_id_in id avoid =
  let id, _ = get_subscript id in
  (* Find the first free subscript for that identifier *)
  let ss = try Subscript.succ (Id.Map.find id avoid) with Not_found -> Subscript.zero in
  let avoid = Id.Map.add id ss avoid in
  (add_subscript id ss, avoid)

let compute_name sigma ~let_in ~pattern flags avoid env na c =
match avoid with
| Nice avoid ->
  let flags =
    if flags.flg_isgoal then RenamingForGoal
    else if pattern then RenamingForCasesPattern (fst env, c)
    else RenamingElsewhereFor (fst env, c)
  in
  let na, avoid =
    if let_in then compute_displayed_let_name_in sigma flags avoid na c
    else compute_displayed_name_in sigma flags avoid na c
  in
  na, Nice avoid
| Fast avoid ->
  (* In fast mode, we use a dumber algorithm but algorithmically more
      efficient algorithm that doesn't iterate through the term to find the
      used constants and variables. *)
  let id = match na with
  | Name id -> id
  | Anonymous ->
    if flags.flg_isgoal then default_non_dependent_ident
    else if pattern then default_dependent_ident
    else default_non_dependent_ident
  in
  let id, avoid = fresh_id_in id avoid in
  (Name id, Fast avoid)

let next_name_away flags na avoid = match avoid with
| Nice avoid ->
  let id = next_name_away na avoid in
  id, Nice (Id.Set.add id avoid)
| Fast avoid ->
  let id = match na with
  | Anonymous -> default_non_dependent_ident
  | Name id -> id
  in
  let id, avoid = fresh_id_in id avoid in
  (id, Fast avoid)

end

let compute_name = Avoid.compute_name
let next_name_away = Avoid.next_name_away

type _ delay =
| Now : 'a delay
| Later : [ `thunk ] delay

(** Should we keep details of universes during detyping ? *)
let print_universes = ref false

(** If true, prints local context of evars, whatever print_arguments *)
let print_evar_arguments = ref false

let add_name na b t (nenv, env) =
  let open Context.Rel.Declaration in
  (* Is this just a dummy? Be careful, printing doesn't always give us
     a correct env. *)
  let r = Sorts.Relevant in
  add_name na nenv, push_rel (match b with
                              | None -> LocalAssum (make_annot na r,t)
                              | Some b -> LocalDef (make_annot na r,b,t)
                             )
                             env

let add_name_opt na b t (nenv, env) =
  match t with
  | None -> Termops.add_name na nenv, env
  | Some t -> add_name na b t (nenv, env)

(****************************************************************************)
(* Tools for printing of Cases                                              *)

let encode_inductive env r =
  let indsp = Nametab.global_inductive r in
  let constr_lengths = constructors_nrealargs env indsp in
  (indsp,constr_lengths)

(* Parameterization of the translation from constr to ast      *)

(* Tables for Cases printing under a "if" form, a "let" form,  *)

let has_two_constructors lc =
  Int.equal (Array.length lc) 2 (* & lc.(0) = 0 & lc.(1) = 0 *)

let isomorphic_to_tuple lc = Int.equal (Array.length lc) 1

let encode_bool env ({CAst.loc} as r) =
  let (x,lc) = encode_inductive env r in
  if not (has_two_constructors lc) then
    user_err ?loc ~hdr:"encode_if"
      (str "This type has not exactly two constructors.");
  x

let encode_tuple env ({CAst.loc} as r) =
  let (x,lc) = encode_inductive env r in
  if not (isomorphic_to_tuple lc) then
    user_err ?loc ~hdr:"encode_tuple"
      (str "This type cannot be seen as a tuple type.");
  x

module PrintingInductiveMake =
  functor (Test : sig
     val encode : Environ.env -> qualid -> inductive
     val member_message : Pp.t -> bool -> Pp.t
     val field : string
     val title : string
  end) ->
  struct
    type t = inductive
    module Set = Indset
    let encode = Test.encode
    let subst subst obj = subst_ind subst obj
    let printer ind = Nametab.pr_global_env Id.Set.empty (GlobRef.IndRef ind)
    let key = ["Printing";Test.field]
    let title = Test.title
    let member_message x = Test.member_message (printer x)
    let synchronous = true
  end

module PrintingCasesIf =
  PrintingInductiveMake (struct
    let encode = encode_bool
    let field = "If"
    let title = "Types leading to pretty-printing of Cases using a `if' form:"
    let member_message s b =
      str "Cases on elements of " ++ s ++
      str
        (if b then " are printed using a `if' form"
         else " are not printed using a `if' form")
  end)

module PrintingCasesLet =
  PrintingInductiveMake (struct
    let encode = encode_tuple
    let field = "Let"
    let title =
      "Types leading to a pretty-printing of Cases using a `let' form:"
    let member_message s b =
      str "Cases on elements of " ++ s ++
      str
        (if b then " are printed using a `let' form"
         else " are not printed using a `let' form")
  end)

module PrintingIf  = Goptions.MakeRefTable(PrintingCasesIf)
module PrintingLet = Goptions.MakeRefTable(PrintingCasesLet)

(* Flags.for printing or not wildcard and synthetisable types *)

open Goptions

let wildcard_value = ref true
let force_wildcard () = !wildcard_value

let () = declare_bool_option
          { optdepr  = false;
            optname  = "forced wildcard";
            optkey   = ["Printing";"Wildcard"];
            optread  = force_wildcard;
            optwrite = (:=) wildcard_value }

let fast_name_generation = ref false

let () = declare_bool_option {
  optdepr = false;
  optname = "fast bound name generation algorithm";
  optkey = ["Fast";"Name";"Printing"];
  optread = (fun () -> !fast_name_generation);
  optwrite = (:=) fast_name_generation;
}

let synth_type_value = ref true
let synthetize_type () = !synth_type_value

let () = declare_bool_option
          { optdepr  = false;
            optname  = "pattern matching return type synthesizability";
            optkey   = ["Printing";"Synth"];
            optread  = synthetize_type;
            optwrite = (:=) synth_type_value }

let reverse_matching_value = ref true
let reverse_matching () = !reverse_matching_value

let () = declare_bool_option
          { optdepr  = false;
            optname  = "pattern-matching reversibility";
            optkey   = ["Printing";"Matching"];
            optread  = reverse_matching;
            optwrite = (:=) reverse_matching_value }

let print_primproj_params_value = ref false
let print_primproj_params () = !print_primproj_params_value

let () = declare_bool_option
          { optdepr  = false;
            optname  = "printing of primitive projection parameters";
            optkey   = ["Printing";"Primitive";"Projection";"Parameters"];
            optread  = print_primproj_params;
            optwrite = (:=) print_primproj_params_value }


(* Auxiliary function for MutCase printing *)
(* [computable] tries to tell if the predicate typing the result is inferable*)

let computable sigma p k =
    (* We first remove as many lambda as the arity, then we look
       if it remains a lambda for a dependent elimination. This function
       works for normal eta-expanded term. For non eta-expanded or
       non-normal terms, it may affirm the pred is synthetisable
       because of an undetected ultimate dependent variable in the second
       clause, or else, it may affirm the pred non synthetisable
       because of a non normal term in the fourth clause.
       A solution could be to store, in the MutCase, the eta-expanded
       normal form of pred to decide if it depends on its variables

       Lorsque le prédicat est dépendant de manière certaine, on
       ne déclare pas le prédicat synthétisable (même si la
       variable dépendante ne l'est pas effectivement) parce que
       sinon on perd la réciprocité de la synthèse (qui, lui,
       engendrera un prédicat non dépendant) *)

  let sign,ccl = decompose_lam_assum sigma p in
  Int.equal (Context.Rel.length sign) (k + 1)
  &&
  noccur_between sigma 1 (k+1) ccl

let lookup_name_as_displayed env sigma t s =
  let rec lookup avoid n c = match EConstr.kind sigma c with
    | Prod (name,_,c') ->
        (match compute_displayed_name_in sigma RenamingForGoal avoid name.binder_name c' with
           | (Name id,avoid') -> if Id.equal id s then Some n else lookup avoid' (n+1) c'
           | (Anonymous,avoid') -> lookup avoid' (n+1) (pop c'))
    | LetIn (name,_,_,c') ->
        (match Namegen.compute_displayed_name_in sigma RenamingForGoal avoid name.binder_name c' with
           | (Name id,avoid') -> if Id.equal id s then Some n else lookup avoid' (n+1) c'
           | (Anonymous,avoid') -> lookup avoid' (n+1) (pop c'))
    | Cast (c,_,_) -> lookup avoid n c
    | _ -> None
  in lookup (Environ.ids_of_named_context_val (Environ.named_context_val env)) 1 t

let lookup_index_as_renamed env sigma t n =
  let rec lookup n d c = match EConstr.kind sigma c with
    | Prod (name,_,c') ->
          (match Namegen.compute_displayed_name_in sigma RenamingForGoal Id.Set.empty name.binder_name c' with
               (Name _,_) -> lookup n (d+1) c'
             | (Anonymous,_) ->
                 if Int.equal n 0 then
                   Some (d-1)
                 else if Int.equal n 1 then
                   Some d
                 else
                   lookup (n-1) (d+1) c')
    | LetIn (name,_,_,c') ->
          (match Namegen.compute_displayed_name_in sigma RenamingForGoal Id.Set.empty name.binder_name c' with
             | (Name _,_) -> lookup n (d+1) c'
             | (Anonymous,_) ->
                 if Int.equal n 0 then
                   Some (d-1)
                 else if Int.equal n 1 then
                   Some d
                 else
                   lookup (n-1) (d+1) c'
          )
    | Cast (c,_,_) -> lookup n d c
    | _ -> if Int.equal n 0 then Some (d-1) else None
  in lookup n 1 t

(**********************************************************************)
(* Factorization of match patterns *)

let print_factorize_match_patterns = ref true

let () =
  declare_bool_option
    { optdepr  = false;
      optname  = "factorization of \"match\" patterns in printing";
      optkey   = ["Printing";"Factorizable";"Match";"Patterns"];
      optread  = (fun () -> !print_factorize_match_patterns);
      optwrite = (fun b -> print_factorize_match_patterns := b) }

let print_allow_match_default_clause = ref true

let () =
  declare_bool_option
    { optdepr  = false;
      optname  = "possible use of \"match\" default pattern in printing";
      optkey   = ["Printing";"Allow";"Match";"Default";"Clause"];
      optread  = (fun () -> !print_allow_match_default_clause);
      optwrite = (fun b -> print_allow_match_default_clause := b) }

let rec join_eqns (ids,rhs as x) patll = function
  | ({CAst.loc; v=(ids',patl',rhs')} as eqn')::rest ->
     if not !Flags.raw_print && !print_factorize_match_patterns &&
        List.eq_set Id.equal ids ids' && glob_constr_eq rhs rhs'
     then
       join_eqns x (patl'::patll) rest
     else
       let eqn,rest = join_eqns x patll rest in
       eqn, eqn'::rest
  | [] ->
     patll, []

let number_of_patterns {CAst.v=(_ids,patll,_rhs)} = List.length patll

let is_default_candidate {CAst.v=(ids,_patll,_rhs)} = ids = []

let rec move_more_factorized_default_candidate_to_end eqn n = function
  | eqn' :: eqns ->
     let set,get = set_temporary_memory () in
     if is_default_candidate eqn' && set (number_of_patterns eqn') >= n then
       let isbest, dft, eqns = move_more_factorized_default_candidate_to_end eqn' (get ()) eqns in
       if isbest then false, dft, eqns else false, dft, eqn' :: eqns
     else
       let isbest, dft, eqns = move_more_factorized_default_candidate_to_end eqn n eqns in
       isbest, dft, eqn' :: eqns
  | [] -> true, Some eqn, []

let rec select_default_clause = function
  | eqn :: eqns ->
     let set,get = set_temporary_memory () in
     if is_default_candidate eqn && set (number_of_patterns eqn) > 1 then
       let isbest, dft, eqns = move_more_factorized_default_candidate_to_end eqn (get ()) eqns in
       if isbest then dft, eqns else dft, eqn :: eqns
     else
       let dft, eqns = select_default_clause eqns in dft, eqn :: eqns
  | [] -> None, []

let factorize_eqns eqns =
  let open CAst in
  let rec aux found = function
  | {loc;v=(ids,patl,rhs)}::rest ->
     let patll,rest = join_eqns (ids,rhs) [patl] rest in
     aux (CAst.make ?loc (ids,patll,rhs)::found) rest
  | [] ->
     found in
  let eqns = aux [] (List.rev eqns) in
  let mk_anon patl = List.map (fun _ -> DAst.make @@ PatVar Anonymous) patl in
  let open CAst in
  if not !Flags.raw_print && !print_allow_match_default_clause && eqns <> [] then
    match select_default_clause eqns with
    (* At least two clauses and the last one is disjunctive with no variables *)
    | Some {loc=gloc;v=([],patl::_::_,rhs)}, (_::_ as eqns) ->
      eqns@[CAst.make ?loc:gloc ([],[mk_anon patl],rhs)]
    (* Only one clause which is disjunctive with no variables: we keep at least one constructor *)
    (* so that it is not interpreted as a dummy "match" *)
    | Some {loc=gloc;v=([],patl::patl'::_,rhs)}, [] ->
      [CAst.make ?loc:gloc ([],[patl;mk_anon patl'],rhs)]
    | Some {v=((_::_,_,_ | _,([]|[_]),_))}, _ -> assert false
    | None, eqns -> eqns
  else
    eqns

(**********************************************************************)
(* Fragile algorithm to reverse pattern-matching compilation          *)

let update_name sigma na ((_,(e,_)),c) =
  match na with
  | Name _ when force_wildcard () && noccurn sigma (List.index Name.equal na e) c ->
      Anonymous
  | _ ->
      na

let rec decomp_branch tags nal flags (avoid,env as e) sigma c =
  match tags with
  | [] -> (List.rev nal,(e,c))
  | b::tags ->
      let na,c,let_in,body,t =
        match EConstr.kind sigma (strip_outer_cast sigma c), b with
        | Lambda (na,t,c),false -> na.binder_name,c,true,None,Some t
        | LetIn (na,b,t,c),true ->
            na.binder_name,c,false,Some b,Some t
        | _, false ->
          Name default_dependent_ident,(applist (lift 1 c, [mkRel 1])),
            false,None,None
        | _, true ->
          Anonymous,lift 1 c,false,None,None
    in
    let na',avoid' = compute_name sigma ~let_in ~pattern:true flags avoid env na c in
    decomp_branch tags (na'::nal) flags
      (avoid', add_name_opt na' body t env) sigma c

let rec build_tree na isgoal e sigma ci cl =
  let mkpat n rhs pl =
    let na = update_name sigma na rhs in
    na, DAst.make @@ PatCstr((ci.ci_ind,n+1),pl,na) in
  let cnl = ci.ci_pp_info.cstr_tags in
  List.flatten
    (List.init (Array.length cl)
      (fun i -> contract_branch isgoal e sigma (cnl.(i),mkpat i,cl.(i))))

and align_tree nal isgoal (e,c as rhs) sigma = match nal with
  | [] -> [Id.Set.empty,[],rhs]
  | na::nal ->
    match EConstr.kind sigma c with
    | Case (ci,p,c,cl) when
        eq_constr sigma c (mkRel (List.index Name.equal na (fst (snd e))))
        && not (Int.equal (Array.length cl) 0)
        && (* don't contract if p dependent *)
        computable sigma p (List.length ci.ci_pp_info.ind_tags) (* FIXME: can do better *) ->
        let clauses = build_tree na isgoal e sigma ci cl in
        List.flatten
          (List.map (fun (ids,pat,rhs) ->
              let lines = align_tree nal isgoal rhs sigma in
              List.map (fun (ids',hd,rest) -> Id.Set.fold Id.Set.add ids ids',pat::hd,rest) lines)
            clauses)
    | _ ->
        let na = update_name sigma na rhs in
        let pat = DAst.make @@ PatVar na in
        let mat = align_tree nal isgoal rhs sigma in
        List.map (fun (ids,hd,rest) -> Nameops.Name.fold_right Id.Set.add na ids,pat::hd,rest) mat

and contract_branch isgoal e sigma (cdn,mkpat,rhs) =
  let nal,rhs = decomp_branch cdn [] isgoal e sigma rhs in
  let mat = align_tree nal isgoal rhs sigma in
  List.map (fun (ids,hd,rhs) ->
      let na, pat = mkpat rhs hd in
      (Nameops.Name.fold_right Id.Set.add na ids, pat, rhs)) mat

(**********************************************************************)
(* Transform internal representation of pattern-matching into list of *)
(* clauses                                                            *)

let is_nondep_branch sigma c l =
  try
    (* FIXME: do better using tags from l *)
    let sign,ccl = decompose_lam_n_decls sigma (List.length l) c in
    noccur_between sigma 1 (Context.Rel.length sign) ccl
  with e when CErrors.noncritical e -> (* Not eta-expanded or not reduced *)
    false

let extract_nondep_branches test c b l =
  let rec strip l r =
    match DAst.get r, l with
      | r', [] -> r
      | GLambda (_,_,_,t), false::l -> strip l t
      | GLetIn (_,_,_,t), true::l -> strip l t
      (* FIXME: do we need adjustment? *)
      | _,_ -> assert false in
  if test c l then Some (strip l b) else None

let it_destRLambda_or_LetIn_names l c =
  let rec aux l nal c =
    match DAst.get c, l with
      | _, [] -> (List.rev nal,c)
      | GLambda (na,_,_,c), false::l -> aux l (na::nal) c
      | GLetIn (na,_,_,c), true::l -> aux l (na::nal) c
      | _, true::l -> (* let-expansion *) aux l (Anonymous :: nal) c
      | _, false::l ->
          (* eta-expansion *)
          let next l =
            let x = next_ident_away default_dependent_ident l in
            (* Not efficient but unusual and no function to get free glob_vars *)
(* 	    if occur_glob_constr x c then next (x::l) else x in *)
            x
          in
          let x = next (free_glob_vars c) in
          let a = DAst.make @@ GVar x in
          aux l (Name x :: nal)
            (match DAst.get c with
              | GApp (p,l) -> DAst.make ?loc:c.CAst.loc @@ GApp (p,l@[a])
              | _ -> DAst.make @@ GApp (c,[a]))
  in aux l [] c

let detype_case computable detype detype_eqns testdep avoid data p c bl =
  let (indsp,st,constagsl,k) = data in
  let synth_type = synthetize_type () in
  let tomatch = detype c in
  let alias, aliastyp, pred=
    if (not !Flags.raw_print) && synth_type && computable && not (Int.equal (Array.length bl) 0)
    then
      Anonymous, None, None
    else
      let p = detype p in
      let nl,typ = it_destRLambda_or_LetIn_names k p in
      let n,typ = match DAst.get typ with
        | GLambda (x,_,t,c) -> x, c
        | _ -> Anonymous, typ in
      let aliastyp =
        if List.for_all (Name.equal Anonymous) nl then None
        else Some (CAst.make (indsp,nl)) in
      n, aliastyp, Some typ
  in
  let constructs = Array.init (Array.length bl) (fun i -> (indsp,i+1)) in
  let tag =
    try
      if !Flags.raw_print then
        RegularStyle
      else if st == LetPatternStyle then
        st
      else if PrintingLet.active indsp then
        LetStyle
      else if PrintingIf.active indsp then
        IfStyle
      else
        st
    with Not_found -> st
  in
  match tag, aliastyp with
  | LetStyle, None ->
      let bl' = Array.map detype bl in
      let (nal,d) = it_destRLambda_or_LetIn_names constagsl.(0) bl'.(0) in
      GLetTuple (nal,(alias,pred),tomatch,d)
  | IfStyle, None ->
      let bl' = Array.map detype bl in
      let nondepbrs =
        Array.map3 (extract_nondep_branches testdep) bl bl' constagsl in
      if Array.for_all ((!=) None) nondepbrs then
        GIf (tomatch,(alias,pred),
             Option.get nondepbrs.(0),Option.get nondepbrs.(1))
      else
        let eqnl = detype_eqns constructs constagsl bl in
        GCases (tag,pred,[tomatch,(alias,aliastyp)],eqnl)
  | _ ->
      let eqnl = detype_eqns constructs constagsl bl in
      GCases (tag,pred,[tomatch,(alias,aliastyp)],eqnl)

let rec share_names detype flags n l avoid env sigma c t =
  match EConstr.kind sigma c, EConstr.kind sigma t with
    (* factorize even when not necessary to have better presentation *)
    | Lambda (na,t,c), Prod (na',t',c') ->
        let na = Nameops.Name.pick_annot na na' in
        let t' = detype flags avoid env sigma t in
        let id, avoid = next_name_away flags na.binder_name avoid in
        let env = add_name (Name id) None t env in
        share_names detype flags (n-1) ((Name id,Explicit,None,t')::l) avoid env sigma c c'
    (* May occur for fix built interactively *)
    | LetIn (na,b,t',c), _ when n > 0 ->
        let t'' = detype flags avoid env sigma t' in
        let b' = detype flags avoid env sigma b in
        let id, avoid = next_name_away flags na.binder_name avoid in
        let env = add_name (Name id) (Some b) t' env in
        share_names detype flags n ((Name id,Explicit,Some b',t'')::l) avoid env sigma c (lift 1 t)
    (* Only if built with the f/n notation or w/o let-expansion in types *)
    | _, LetIn (_,b,_,t) when n > 0 ->
        share_names detype flags n l avoid env sigma c (subst1 b t)
    (* If it is an open proof: we cheat and eta-expand *)
    | _, Prod (na',t',c') when n > 0 ->
        let t'' = detype flags avoid env sigma t' in
        let id, avoid = next_name_away flags na'.binder_name avoid in
        let env = add_name (Name id) None t' env in
        let appc = mkApp (lift 1 c,[|mkRel 1|]) in
        share_names detype flags (n-1) ((Name id,Explicit,None,t'')::l) avoid env sigma appc c'
    (* If built with the f/n notation: we renounce to share names *)
    | _ ->
        if n>0 then Feedback.msg_debug (strbrk "Detyping.detype: cannot factorize fix enough");
        let c = detype flags avoid env sigma c in
        let t = detype flags avoid env sigma t in
        (List.rev l,c,t)

let rec share_pattern_names detype n l avoid env sigma c t =
  let open Pattern in
  if n = 0 then
    let c = detype avoid env sigma c in
    let t = detype avoid env sigma t in
    (List.rev l,c,t)
  else match c, t with
    | PLambda (na,t,c), PProd (na',t',c') ->
        let na = match (na,na') with
            Name _, _ -> na
          | _, Name _ -> na'
          | _ -> na in
        let t' = detype avoid env sigma t in
        let id = Namegen.next_name_away na avoid in
        let avoid = Id.Set.add id avoid in
        let env = Name id :: env in
        share_pattern_names detype (n-1) ((Name id,Explicit,None,t')::l) avoid env sigma c c'
    | _ ->
        if n>0 then Feedback.msg_debug (strbrk "Detyping.detype: cannot factorize fix enough");
        let c = detype avoid env sigma c in
        let t = detype avoid env sigma t in
        (List.rev l,c,t)

let detype_fix detype flags avoid env sigma (vn,_ as nvn) (names,tys,bodies) =
  let def_avoid, def_env, lfi =
    Array.fold_left2
      (fun (avoid, env, l) na ty ->
         let id, avoid = next_name_away flags na.binder_name avoid in
         (avoid, add_name (Name id) None ty env, id::l))
      (avoid, env, []) names tys in
  let n = Array.length tys in
  let v = Array.map3
    (fun c t i -> share_names detype flags (i+1) [] def_avoid def_env sigma c (lift n t))
    bodies tys vn in
  GRec(GFix (Array.map (fun i -> Some i) (fst nvn), snd nvn),Array.of_list (List.rev lfi),
       Array.map (fun (bl,_,_) -> bl) v,
       Array.map (fun (_,_,ty) -> ty) v,
       Array.map (fun (_,bd,_) -> bd) v)

let detype_cofix detype flags avoid env sigma n (names,tys,bodies) =
  let def_avoid, def_env, lfi =
    Array.fold_left2
      (fun (avoid, env, l) na ty ->
         let id, avoid = next_name_away flags na.binder_name avoid in
         (avoid, add_name (Name id) None ty env, id::l))
      (avoid, env, []) names tys in
  let ntys = Array.length tys in
  let v = Array.map2
    (fun c t -> share_names detype flags 0 [] def_avoid def_env sigma c (lift ntys t))
    bodies tys in
  GRec(GCoFix n,Array.of_list (List.rev lfi),
       Array.map (fun (bl,_,_) -> bl) v,
       Array.map (fun (_,_,ty) -> ty) v,
       Array.map (fun (_,bd,_) -> bd) v)

(* TODO use some algebraic type with a case for unnamed univs so we
   can cleanly detype them. NB: this corresponds to a hack in
   Pretyping.interp_universe_level_name to convert Foo.xx strings into
   universes. *)
let hack_qualid_of_univ_level sigma l =
  match Termops.reference_of_level sigma l with
  | Some qid -> qid
  | None ->
    let path = String.split_on_char '.' (Univ.Level.to_string l) in
    let path = List.rev_map Id.of_string_soft path in
    Libnames.qualid_of_dirpath (DirPath.make path)

let detype_universe sigma u =
  let fn (l, n) =
    let s =
      if Univ.Level.is_prop l then GProp else
      if Univ.Level.is_set l then GSet else
      GType (hack_qualid_of_univ_level sigma l) in
    (s, n) in
  Univ.Universe.map fn u

let detype_sort sigma = function
  | SProp -> UNamed [GSProp,0]
  | Prop -> UNamed [GProp,0]
  | Set -> UNamed [GSet,0]
  | Type u ->
      (if !print_universes
       then UNamed (detype_universe sigma u)
       else UAnonymous {rigid=true})

type binder_kind = BProd | BLambda | BLetIn

(**********************************************************************)
(* Main detyping function                                             *)

let detype_level sigma l =
  let l = hack_qualid_of_univ_level sigma l in
  UNamed (GType l)

let detype_instance sigma l =
  let l = EInstance.kind sigma l in
  if Univ.Instance.is_empty l then None
  else Some (List.map (detype_level sigma) (Array.to_list (Univ.Instance.to_array l)))

let delay (type a) (d : a delay) (f : a delay -> _ -> _ -> _ -> _ -> _ -> a glob_constr_r) flags env avoid sigma t : a glob_constr_g =
  match d with
  | Now -> DAst.make (f d flags env avoid sigma t)
  | Later -> DAst.delay (fun () -> f d flags env avoid sigma t)

let inductive_to_string i =
  let _, (i : Declarations.one_inductive_body) = Global.lookup_inductive i in
  Id.to_string i.mind_typename

let constructor_to_string (ind, x) =
  let _, (ind : Declarations.one_inductive_body) = Global.lookup_inductive ind in
  let constr = ind.mind_consnames.(x - 1) in
  Id.to_string constr

open Context.Rel

let print_rel_context (ctx : Constr.rel_context) =
  let i = ref 1 in
  List.iter (fun decl ->
    let name =
      match decl with
      | Context.Rel.Declaration.LocalAssum (na, _)
      | Context.Rel.Declaration.LocalDef (na, _, _) ->
        match na.Context.binder_name with
        | Names.Name id -> Names.Id.to_string id
        | Names.Anonymous -> "_"
    in
    Printf.printf "  [%d]: %s (Rel %d)\n" !i name !i;
    incr i
  ) ctx


let rec find_rel_binding env sigma n =
  let rec process_context depth ctx =
    match ctx with
    | [] -> None 
    | decl :: rest ->
        if depth = n then
          match Context.Rel.Declaration.get_name decl with
          | Names.Name id -> Some id
          | Names.Anonymous -> 
              (* 如果是匿名的,尝试从类型中获取更多信息 *)
              let typ = Context.Rel.Declaration.get_type decl in
              Some (Id.of_string ("_R" ^ string_of_int n))
        else process_context (depth + 1) rest
  in
  let rel_ctx = Environ.rel_context env in
  process_context 1 rel_ctx

let rec print_type_as_string env sigma id typ =
  let typ_constr = EConstr.to_constr sigma typ in
  let rec print_type_rec k env sigma id typ =
    match EConstr.kind sigma typ with
    | Rel n ->
      begin
        let rel_ctx = Environ.rel_context env in
        match rel_ctx with
        | [] ->
          (let ctx, _ = Term.decompose_prod_assum typ_constr in
          Printf.printf "Handling Rel(%d)\n" n;
          Printf.printf "Current full context:\n";
          List.iter (fun decl ->
            match Context.Rel.Declaration.get_name decl with
            | Names.Name id -> Printf.printf "%s\n" (Id.to_string id)
            | Names.Anonymous -> Printf.printf "_\n"
          ) ctx;
          try
            let decl = Context.Rel.lookup n ctx in
            match Context.Rel.Declaration.get_name decl with
            | Names.Name id -> Id.to_string id
            | Names.Anonymous -> "Rel(" ^ string_of_int n ^ ")"
          with Not_found ->
            "Rel(" ^ string_of_int n ^ ")")
        | _ ->
          (* 需要调整索引：n-k 才是在原始环境中的正确索引 *)
          begin
            let rel_ctx = Environ.rel_context env in
            Printf.printf "\nLooking for Rel(%d) with depth=%d\n" n k;
            Printf.printf "Handling Rel(%d)\n" n;
            Printf.printf "Current Rel Context:\n";
            print_rel_context rel_ctx;
            try
              let decl = EConstr.lookup_rel (n+k) env in
              match Declaration.get_name decl with
              | Names.Name id -> Id.to_string id
              | Names.Anonymous -> 
                  (* 对于匿名绑定，尝试从类型获取更多信息 *)
                  let typ = Declaration.get_type decl in
                  print_type_rec (k + 1) env sigma id (lift (n+k) typ)
            with Not_found -> 
              let not_found_str = "rel:" ^ string_of_int n in
              (* Printf.printf "Not_found for Rel(%d)\n" n; *)
              not_found_str
          end
      end
    (* | Rel n -> "Rel(" ^ string_of_int n ^ ")" *)
    (* | Rel n ->
        (* n是相对于当前环境的de Bruijn索引 *)
        (* k是当前递归深度，表示经过了多少层绑定 *)
          (* if n <= k then
          (* 如果索引小于等于当前深度，说明是引用当前Lambda/Prod等绑定的变量 *)
          "_" ^ string_of_int n
        else *)
        begin
          let rel_ctx = Environ.rel_context env in
          match rel_ctx with
          | [] ->
            (* 如果在rel context中找不到，尝试named context *)
            begin
              try
                let named_ctx = Environ.named_context env in
                let rel_ctx = List.map (fun decl ->
                  Context.Named.Declaration.to_rel_decl decl
                ) (List.rev named_ctx) in
                Printf.printf "Handling Rel(%d)\n" n;
                Printf.printf "Current Rel Context:\n";
                print_rel_context rel_ctx;
                let decl = Rel.lookup n rel_ctx in
                match Declaration.get_name decl with
                | Names.Name id -> 
                  let name_str = Id.to_string id in
                  name_str
                | Names.Anonymous -> 
                  let anon_str = "_" ^ string_of_int n in
                  (* Printf.printf "Anonymous Rel(%d)\n" n; *)
                  anon_str
              with Invalid_argument _ | Failure _ ->
                "rel:" ^ string_of_int n
            end
          | _ ->
            (* 需要调整索引：n-k 才是在原始环境中的正确索引 *)
            begin
              let rel_ctx = Environ.rel_context env in
              Printf.printf "\nLooking for Rel(%d) with depth=%d\n" n k;
              Printf.printf "Handling Rel(%d)\n" n;
              Printf.printf "Current Rel Context:\n";
              print_rel_context rel_ctx;
              try
                let decl = EConstr.lookup_rel (n-k) env in
                match Declaration.get_name decl with
                | Names.Name id -> Id.to_string id
                | Names.Anonymous -> 
                    (* 对于匿名绑定，尝试从类型获取更多信息 *)
                    let typ = Declaration.get_type decl in
                    print_type_rec 0 env sigma id (lift (n-k) typ)
              with Not_found -> 
                let not_found_str = "rel:" ^ string_of_int n in
                (* Printf.printf "Not_found for Rel(%d)\n" n; *)
                not_found_str
            end
        end *)
    | App (f, args) ->
      (* "app:" ^ Pp.string_of_ppcmds (debug_print typ_constr) *)
      (* Pp.string_of_ppcmds (debug_print typ_constr) *)
      let f_str = print_type_rec k env sigma id f in
      let args_str = Array.fold_right (fun arg acc -> 
        let arg_str = print_type_rec (k+1) env sigma id arg in
        arg_str ^ (if acc <> "" then " " ^ acc else "")
      ) args "" in
      "( " ^ f_str ^ " " ^ args_str ^ " )"
    (* | Ind (ind, u) ->
      (* "ind:" ^ inductive_to_string ind ^ " uni:" ^ print_universe_instance sigma u *)
      inductive_to_string ind *)
    | Ind ((mind, i), u) ->
      let mind_str = MutInd.to_string mind in
      let ind_str = inductive_to_string (mind, i) in
      mind_str ^ "." ^ ind_str
    | Lambda (na, t1, t2) ->
      let name = match Context.binder_name na with
        | Names.Name id -> Id.to_string id 
        | Names.Anonymous -> "_"
      in
      let t1_str = print_type_rec k env sigma id t1 in
      let t2_str = print_type_rec (k+1) env sigma id t2 in
      "( " ^ t1_str ^ " => " ^ t2_str ^ " )"
    | Case (ci, p, c, brs) ->
      let c_str = print_type_rec k env sigma id c in
      let brs_str = Array.fold_left (fun acc br ->
        let br_str = print_type_rec k env sigma id br in
        acc ^ (if acc <> "" then " | " else "") ^ br_str
      ) "" brs in
      brs_str
    | Fix ((vn,i), (nams, tys, bds)) ->
      let fix_name = match Context.binder_name (Array.get nams i) with
        | Names.Name id -> Id.to_string id
        | Names.Anonymous -> "_" 
      in
      let ty_str = print_type_rec k env sigma id (Array.get tys i) in
      let body_str = print_type_rec (k+1) env sigma id (Array.get bds i) in
      "TYPE: " ^ ty_str ^ "BODY: " ^ body_str
    | CoFix (i, (nams, tys, bds)) ->
      let cofix_name = match Context.binder_name (Array.get nams i) with
        | Names.Name id -> Id.to_string id
        | Names.Anonymous -> "_"
      in
      let ty_str = print_type_rec k env sigma id (Array.get tys i) in
      let body_str = print_type_rec (k+1) env sigma id (Array.get bds i) in
      "TYPE: " ^ ty_str ^ "BODY: " ^ body_str
    | Construct (((mind, i), j), u) ->
      let ind_name = MutInd.to_string mind in
      let actual_name = constructor_to_string ((mind, i), j) in
      let full_name = ind_name ^ "." ^ actual_name in
      full_name
    | Proj (p, c') -> 
      let proj_name = Constant.to_string (Projection.constant p) in
      let c_str = print_type_rec k env sigma id c' in
      proj_name ^ "." ^ c_str
    | Const (c, u) ->
      (* "const:" ^ Label.to_string (Constant.label c) ^ " uni:" ^ print_universe_instance sigma u *)
      let const_name = Constant.to_string c in
      const_name
    | Var id ->
      (* "var:" ^ Id.to_string id *)
      Id.to_string id
    | Evar (ev, cl) ->
        let evi = Evd.find sigma ev in
        (* "evar:" ^ print_type env sigma id evi.evar_concl *)
        print_type_rec k env sigma id evi.evar_concl
      (* with Not_found -> "evar:unknown") *)
      (* with Not_found -> "unknown" *)
    | Int i ->
      (* "int:" ^ Uint63.to_string i *)
      Uint63.to_string i
    | Float f ->
      (* "float:" ^ Float64.to_string f *)
      Float64.to_string f
    | Prod (na, t1, t2) ->
      let name = match Context.binder_name na with
        | Names.Name id -> Id.to_string id 
        (* | Names.Anonymous -> "_" *)
        | Names.Anonymous -> ""
      in
      let t1_str = print_type_rec k env sigma id t1 in
      let t2_str = print_type_rec (k+1) env sigma id t2 in
      "forall " ^ name ^ " : " ^ t1_str ^ " -> " ^ t2_str
      (* let base_name = match Context.binder_name na with
      | Names.Name id -> Id.to_string id 
      | Names.Anonymous -> "_"
      in
      let name = 
        if base_name = "_" then "_" 
        else
          let rec make_unique n =
            let proposed = if n = 0 then base_name 
                          else base_name ^ string_of_int n in
            (* 检查是否已在环境中存在 *)
            if List.exists (fun decl ->
              match Context.Rel.Declaration.get_name decl with
              | Names.Name id -> Id.to_string id = proposed
              | Names.Anonymous -> false
            ) (Environ.rel_context env)
            then make_unique (n + 1)
            else proposed
          in
          make_unique 0
      in
      let t1_str = print_type_rec k env sigma id t1 in
      let t2_str = print_type_rec (k+1) env sigma id t2 in
      "forall " ^ name ^ " : " ^ t1_str ^ " -> " ^ t2_str *)
    | LetIn (na, t1, ty, t2) ->
      let name = match Context.binder_name na with
        | Names.Name id -> Id.to_string id
        | Names.Anonymous -> "_"
      in
      let t1_str = print_type_rec k env sigma id t1 in
      let ty_str = print_type_rec k env sigma id ty in
      let t2_str = print_type_rec (k+1) env sigma id t2 in
      "let " ^ name ^ " : " ^ ty_str ^ " := " ^ t1_str ^ " in " ^ t2_str
    | Sort s ->
      (* begin match ESorts.kind sigma s with
      | Sorts.SProp -> "sort:SProp"
      | Sorts.Prop -> "sort:Prop" 
      | Sorts.Set -> "sort:Set"
      | Sorts.Type u -> "sort:Type"
      end *)
      begin match ESorts.kind sigma s with
      | Sorts.SProp -> "SProp"
      | Sorts.Prop -> "Prop" 
      | Sorts.Set -> "Set"
      | Sorts.Type u -> "Type"
      end
    | _ ->
      (* "other:" ^ Pp.string_of_ppcmds (debug_print typ_constr) *)
      Pp.string_of_ppcmds (debug_print typ_constr)
  in
  print_type_rec 0 env sigma id typ

let rec detype d flags avoid env sigma t =
  delay d detype_r flags avoid env sigma t

and detype_r d flags avoid env sigma t =
  match EConstr.kind sigma (collapse_appl sigma t) with
    | Rel n ->
      (try match lookup_name_of_rel n (fst env) with
          | Name id   -> GVar id
          | Anonymous ->
            let s = "_ANONYMOUS_REL_"^(string_of_int n) in
            GVar (Id.of_string s)
        with Not_found ->
          let s = "_UNBOUND_REL_"^(string_of_int n)
          in GVar (Id.of_string s))
      (* begin 
        match find_rel_binding (snd env) sigma n with
        | Some id -> 
            Printf.printf "Found binding for Rel(%d): %s\n" n (Id.to_string id);
            GVar id
        | None ->
            (* 如果在直接上下文中找不到,尝试查找更大的上下文 *)
            try 
              let full_ctx = Global.env() in
              match find_rel_binding full_ctx sigma n with
              | Some id ->
                  Printf.printf "Found binding in global context for Rel(%d): %s\n" n (Id.to_string id);
                  GVar id
              | None -> 
                  let s = "_UNBOUND_REL_"^(string_of_int n) in
                  Printf.printf "No binding found for Rel(%d)\n" n;
                  GVar (Id.of_string s)
            with _ ->
              let s = "_UNBOUND_REL_"^(string_of_int n) in
              Printf.printf "Failed to find binding for Rel(%d)\n" n;
              GVar (Id.of_string s)
      end *)
    | Meta n ->
        (* Meta in constr are not user-parsable and are mapped to Evar *)
        if n = Constr_matching.special_meta then
          (* Using a dash to be unparsable *)
          GEvar (Id.of_string_soft "CONTEXT-HOLE", [])
        else
          GEvar (Id.of_string_soft ("M" ^ string_of_int n), [])
    | Var id ->
        (* Discriminate between section variable and non-section variable *)
        (try let _ = Global.lookup_named id in GRef (GlobRef.VarRef id, None)
         with Not_found -> GVar id)
         (* (try 
         let decl = Global.lookup_named id in
         let var_type = Context.Named.Declaration.get_type decl in
         Printf.printf "Variable %s has type: %s\n" 
           (Id.to_string id) 
           (print_type_as_string (Global.env()) sigma id (EConstr.of_constr var_type));
         let _ = Global.lookup_named id in 
         GRef (GlobRef.VarRef id, None)
        with Not_found -> 
         Printf.printf "Non-section variable %s\n" (Id.to_string id);
         GVar id) *)
    | Sort s -> GSort (detype_sort sigma (ESorts.kind sigma s))
    | Cast (c1,REVERTcast,c2) when not !Flags.raw_print ->
        DAst.get (detype d flags avoid env sigma c1)
    | Cast (c1,k,c2) ->
        let d1 = detype d flags avoid env sigma c1 in
        let d2 = detype d flags avoid env sigma c2 in
    let cast = match k with
    | VMcast -> CastVM d2
    | NATIVEcast -> CastNative d2
    | _ -> CastConv d2
    in
        GCast(d1,cast)
    | Prod (na,ty,c) -> detype_binder d flags BProd avoid env sigma na None ty c
    | Lambda (na,ty,c) -> detype_binder d flags BLambda avoid env sigma na None ty c
    | LetIn (na,b,ty,c) -> detype_binder d flags BLetIn avoid env sigma na (Some b) ty c
    | App (f,args) ->
      let mkapp f' args' =
        match DAst.get f' with
        | GApp (f',args'') ->
          GApp (f',args''@args')
        | _ -> GApp (f',args')
      in
      mkapp (detype d flags avoid env sigma f)
        (Array.map_to_list (detype d flags avoid env sigma) args)
    | Const (sp,u) -> GRef (GlobRef.ConstRef sp, detype_instance sigma u)
    | Proj (p,c) ->
      let noparams () =
        let pars = Projection.npars p in
        let hole = DAst.make @@ GHole(Evar_kinds.InternalHole,Namegen.IntroAnonymous,None) in
        let args = List.make pars hole in
        GApp (DAst.make @@ GRef (GlobRef.ConstRef (Projection.constant p), None),
              (args @ [detype d flags avoid env sigma c]))
      in
      if flags.flg_lax || !Flags.in_debugger || !Flags.in_toplevel then
        try noparams ()
        with _ ->
            (* lax mode, used by debug printers only *)
          GApp (DAst.make @@ GRef (GlobRef.ConstRef (Projection.constant p), None),
                [detype d flags avoid env sigma c])
      else
        if print_primproj_params () then
          try
            let c = Retyping.expand_projection (snd env) sigma p c [] in
            DAst.get (detype d flags avoid env sigma c)
          with Retyping.RetypeError _ -> noparams ()
        else noparams ()

    | Evar (evk,cl) ->
        let bound_to_itself_or_letin decl c =
          match decl with
          | LocalDef _ -> true
          | LocalAssum (id,_) ->
             try let n = List.index Name.equal (Name id.binder_name) (fst env) in
                 isRelN sigma n c
             with Not_found -> isVarId sigma id.binder_name c
        in
      let id,l =
        try
          let id = match Evd.evar_ident evk sigma with
          | None -> Termops.evar_suggested_name evk sigma
          | Some id -> id
          in
          let l = Evd.evar_instance_array bound_to_itself_or_letin (Evd.find sigma evk) cl in
          let fvs,rels = List.fold_left (fun (fvs,rels) (_,c) -> match EConstr.kind sigma c with Rel n -> (fvs,Int.Set.add n rels) | Var id -> (Id.Set.add id fvs,rels) | _ -> (fvs,rels)) (Id.Set.empty,Int.Set.empty) l in
          let l = Evd.evar_instance_array (fun d c -> not !print_evar_arguments && (bound_to_itself_or_letin d c && not (isRel sigma c && Int.Set.mem (destRel sigma c) rels || isVar sigma c && (Id.Set.mem (destVar sigma c) fvs)))) (Evd.find sigma evk) cl in
          id,l
        with Not_found ->
          Id.of_string ("X" ^ string_of_int (Evar.repr evk)),
          (Array.map_to_list (fun c -> (Id.of_string "__",c)) cl)
      in
        GEvar (id,
               List.map (on_snd (detype d flags avoid env sigma)) l)
    | Ind (ind_sp,u) ->
        GRef (GlobRef.IndRef ind_sp, detype_instance sigma u)
    | Construct (cstr_sp,u) ->
        GRef (GlobRef.ConstructRef cstr_sp, detype_instance sigma u)
    | Case (ci,p,c,bl) ->
        let comp = computable sigma p (List.length (ci.ci_pp_info.ind_tags)) in
        detype_case comp (detype d flags avoid env sigma)
          (detype_eqns d flags avoid env sigma ci comp)
          (is_nondep_branch sigma) avoid
          (ci.ci_ind,ci.ci_pp_info.style,
           ci.ci_pp_info.cstr_tags,ci.ci_pp_info.ind_tags)
          p c bl
    | Fix (nvn,recdef) -> detype_fix (detype d) flags avoid env sigma nvn recdef
    | CoFix (n,recdef) -> detype_cofix (detype d) flags avoid env sigma n recdef
    | Int i -> GInt i
    | Float f -> GFloat f

and detype_eqns d flags avoid env sigma ci computable constructs consnargsl bl =
  try
    if !Flags.raw_print || not (reverse_matching ()) then raise Exit;
    let mat = build_tree Anonymous flags (avoid,env) sigma ci bl in
    List.map (fun (ids,pat,((avoid,env),c)) ->
        CAst.make (Id.Set.elements ids,[pat],detype d flags avoid env sigma c))
      mat
  with e when CErrors.noncritical e ->
    Array.to_list
      (Array.map3 (detype_eqn d flags avoid env sigma) constructs consnargsl bl)

and detype_eqn d flags avoid env sigma constr construct_nargs branch =
  let make_pat x avoid env b body ty ids =
    if force_wildcard () && noccurn sigma 1 b then
      DAst.make @@ PatVar Anonymous,avoid,(add_name Anonymous body ty env),ids
    else
      let na,avoid' = compute_name sigma ~let_in:false ~pattern:true flags avoid env x b in
      DAst.make (PatVar na),avoid',(add_name na body ty env),add_vname ids na
  in
  let rec buildrec ids patlist avoid env l b =
    match EConstr.kind sigma b, l with
      | _, [] -> CAst.make @@
        (Id.Set.elements ids,
         [DAst.make @@ PatCstr(constr, List.rev patlist,Anonymous)],
         detype d flags avoid env sigma b)
      | Lambda (x,t,b), false::l ->
            let pat,new_avoid,new_env,new_ids = make_pat x.binder_name avoid env b None t ids in
            buildrec new_ids (pat::patlist) new_avoid new_env l b

      | LetIn (x,b,t,b'), true::l ->
            let pat,new_avoid,new_env,new_ids = make_pat x.binder_name avoid env b' (Some b) t ids in
            buildrec new_ids (pat::patlist) new_avoid new_env l b'

      | Cast (c,_,_), l ->    (* Oui, il y a parfois des cast *)
            buildrec ids patlist avoid env l c

      | _, true::l ->
            let pat = DAst.make @@ PatVar Anonymous in
            buildrec ids (pat::patlist) avoid env l b

      | _, false::l ->
            (* eta-expansion : n'arrivera plus lorsque tous les
               termes seront construits à partir de la syntaxe Cases *)
            (* nommage de la nouvelle variable *)
            let new_b = applist (lift 1 b, [mkRel 1]) in
            let pat,new_avoid,new_env,new_ids =
              make_pat Anonymous avoid env new_b None mkProp ids in
            buildrec new_ids (pat::patlist) new_avoid new_env l new_b

  in
  buildrec Id.Set.empty [] avoid env construct_nargs branch

and detype_binder d flags bk avoid env sigma {binder_name=na} body ty c =
  let na',avoid' = match bk with
  | BLetIn -> compute_name sigma ~let_in:true ~pattern:false flags avoid env na c
  | _ -> compute_name sigma ~let_in:false ~pattern:false flags avoid env na c in
  let r =  detype d flags avoid' (add_name na' body ty env) sigma c in
  match bk with
  | BProd   -> GProd (na',Explicit,detype d { flags with flg_isgoal = false } avoid env sigma ty, r)
  | BLambda -> GLambda (na',Explicit,detype d { flags with flg_isgoal = false } avoid env sigma ty, r)
  | BLetIn ->
      let c = detype d { flags with flg_isgoal = false } avoid env sigma (Option.get body) in
      (* Heuristic: we display the type if in Prop *)
      let s = try Retyping.get_sort_family_of (snd env) sigma ty with _ when !Flags.in_debugger || !Flags.in_toplevel -> InType (* Can fail because of sigma missing in debugger *) in
      let t = if s != InProp  && not !Flags.raw_print then None else Some (detype d { flags with flg_isgoal = false } avoid env sigma ty) in
      GLetIn (na', c, t, r)

let detype_rel_context d flags where avoid env sigma sign =
  let where = Option.map (fun c -> EConstr.it_mkLambda_or_LetIn c sign) where in
  let rec aux avoid env = function
  | [] -> []
  | decl::rest ->
      let open Context.Rel.Declaration in
      let na = get_name decl in
      let t = get_type decl in
      let na',avoid' =
        match where with
        | None -> na,avoid
        | Some c ->
          compute_name sigma ~let_in:(is_local_def decl) ~pattern:false flags avoid env na c
      in
      let b = match decl with
              | LocalAssum _ -> None
              | LocalDef (_,b,_) -> Some b
      in
      let b' = Option.map (detype d flags avoid env sigma) b in
      let t' = detype d flags avoid env sigma t in
      (na',Explicit,b',t') :: aux avoid' (add_name na' b t env) rest
  in aux avoid env (List.rev sign)

let detype_names isgoal avoid nenv env sigma t =
  let flags = { flg_isgoal = isgoal; flg_lax = false } in
  let avoid = Avoid.make ~fast:!fast_name_generation avoid in
  detype Now flags avoid (nenv,env) sigma t
let detype d ?(lax=false) isgoal avoid env sigma t =
  let flags = { flg_isgoal = isgoal; flg_lax = lax } in
  let avoid = Avoid.make ~fast:!fast_name_generation avoid in
  detype d flags avoid (names_of_rel_context env, env) sigma t

let detype_rel_context d ?(lax = false) where avoid env sigma sign =
  let flags = { flg_isgoal = false; flg_lax = lax } in
  let avoid = Avoid.make ~fast:!fast_name_generation avoid in
  detype_rel_context d flags where avoid env sigma sign

let detype_closed_glob ?lax isgoal avoid env sigma t =
  let open Context.Rel.Declaration in
  let convert_id cl id =
    try Id.Map.find id cl.idents
    with Not_found -> id
  in
  let convert_name cl = function
    | Name id -> Name (convert_id cl id)
    | Anonymous -> Anonymous
  in
  let rec detype_closed_glob cl cg : Glob_term.glob_constr = DAst.map (function
    | GVar id ->
        (* if [id] is bound to a name. *)
        begin try
          GVar(Id.Map.find id cl.idents)
        (* if [id] is bound to a typed term *)
        with Not_found -> try
          (* assumes [detype] does not raise [Not_found] exceptions *)
          let (b,c) = Id.Map.find id cl.typed in
          (* spiwack: I'm not sure it is the right thing to do,
             but I'm computing the detyping environment like
             [Printer.pr_constr_under_binders_env] does. *)
          let assums = List.map (fun id -> LocalAssum (make_annot (Name id) Sorts.Relevant,(* dummy *) mkProp)) b in
          let env = push_rel_context assums env in
          DAst.get (detype Now ?lax isgoal avoid env sigma c)
        (* if [id] is bound to a [closed_glob_constr]. *)
        with Not_found -> try
          let {closure;term} = Id.Map.find id cl.untyped in
          DAst.get (detype_closed_glob closure term)
        (* Otherwise [id] stands for itself *)
        with Not_found ->
         GVar id
        end
    | GLambda (id,k,t,c) ->
        let id = convert_name cl id in
        GLambda(id,k,detype_closed_glob cl t, detype_closed_glob cl c)
    | GProd (id,k,t,c) ->
        let id = convert_name cl id in
        GProd(id,k,detype_closed_glob cl t, detype_closed_glob cl c)
    | GLetIn (id,b,t,e) ->
        let id = convert_name cl id in
        GLetIn(id,detype_closed_glob cl b, Option.map (detype_closed_glob cl) t, detype_closed_glob cl e)
    | GLetTuple (ids,(n,r),b,e) ->
        let ids = List.map (convert_name cl) ids in
        let n = convert_name cl n in
        GLetTuple (ids,(n,r),detype_closed_glob cl b, detype_closed_glob cl e)
    | GCases (sty,po,tml,eqns) ->
        let (tml,eqns) =
          Glob_ops.map_pattern_binders (fun na -> convert_name cl na) tml eqns
        in
        let (tml,eqns) =
          Glob_ops.map_pattern (fun c -> detype_closed_glob cl c) tml eqns
        in
        GCases(sty,po,tml,eqns)
    | c ->
        DAst.get (Glob_ops.map_glob_constr (detype_closed_glob cl) cg)
    ) cg
  in
  detype_closed_glob t.closure t.term

(**********************************************************************)
(* Module substitution: relies on detyping                            *)

let rec subst_cases_pattern subst = DAst.map (function
  | PatVar _ as pat -> pat
  | PatCstr (((kn,i),j),cpl,n) as pat ->
      let kn' = subst_mind subst kn
      and cpl' = List.Smart.map (subst_cases_pattern subst) cpl in
        if kn' == kn && cpl' == cpl then pat else
          PatCstr (((kn',i),j),cpl',n)
  )

let (f_subst_genarg, subst_genarg_hook) = Hook.make ()

let rec subst_glob_constr env subst = DAst.map (function
  | GRef (ref,u) as raw ->
    let ref',t = subst_global subst ref in
    if ref' == ref then raw else (match t with
        | None -> GRef (ref', u)
        | Some t ->
          let evd = Evd.from_env env in
          let t = t.Univ.univ_abstracted_value in (* XXX This seems dangerous *)
          DAst.get (detype Now false Id.Set.empty env evd (EConstr.of_constr t)))

  | GSort _
  | GVar _
  | GEvar _
  | GInt _
  | GFloat _
  | GPatVar _ as raw -> raw

  | GApp (r,rl) as raw ->
      let r' = subst_glob_constr env subst r
      and rl' = List.Smart.map (subst_glob_constr env subst) rl in
        if r' == r && rl' == rl then raw else
          GApp(r',rl')

  | GLambda (n,bk,r1,r2) as raw ->
      let r1' = subst_glob_constr env subst r1 and r2' = subst_glob_constr env subst r2 in
        if r1' == r1 && r2' == r2 then raw else
          GLambda (n,bk,r1',r2')

  | GProd (n,bk,r1,r2) as raw ->
      let r1' = subst_glob_constr env subst r1 and r2' = subst_glob_constr env subst r2 in
        if r1' == r1 && r2' == r2 then raw else
          GProd (n,bk,r1',r2')

  | GLetIn (n,r1,t,r2) as raw ->
      let r1' = subst_glob_constr env subst r1 in
      let r2' = subst_glob_constr env subst r2 in
      let t' = Option.Smart.map (subst_glob_constr env subst) t in
        if r1' == r1 && t == t' && r2' == r2 then raw else
          GLetIn (n,r1',t',r2')

  | GCases (sty,rtno,rl,branches) as raw ->
    let open CAst in
      let rtno' = Option.Smart.map (subst_glob_constr env subst) rtno
      and rl' = List.Smart.map (fun (a,x as y) ->
        let a' = subst_glob_constr env subst a in
        let (n,topt) = x in
        let topt' = Option.Smart.map
          (fun ({loc;v=((sp,i),y)} as t) ->
            let sp' = subst_mind subst sp in
            if sp == sp' then t else CAst.(make ?loc ((sp',i),y))) topt in
        if a == a' && topt == topt' then y else (a',(n,topt'))) rl
      and branches' = List.Smart.map
                        (fun ({loc;v=(idl,cpl,r)} as branch) ->
                           let cpl' =
                             List.Smart.map (subst_cases_pattern subst) cpl
                           and r' = subst_glob_constr env subst r in
                             if cpl' == cpl && r' == r then branch else
                               CAst.(make ?loc (idl,cpl',r')))
                        branches
      in
        if rtno' == rtno && rl' == rl && branches' == branches then raw else
          GCases (sty,rtno',rl',branches')

  | GLetTuple (nal,(na,po),b,c) as raw ->
      let po' = Option.Smart.map (subst_glob_constr env subst) po
      and b' = subst_glob_constr env subst b
      and c' = subst_glob_constr env subst c in
        if po' == po && b' == b && c' == c then raw else
          GLetTuple (nal,(na,po'),b',c')

  | GIf (c,(na,po),b1,b2) as raw ->
      let po' = Option.Smart.map (subst_glob_constr env subst) po
      and b1' = subst_glob_constr env subst b1
      and b2' = subst_glob_constr env subst b2
      and c' = subst_glob_constr env subst c in
        if c' == c && po' == po && b1' == b1 && b2' == b2 then raw else
          GIf (c',(na,po'),b1',b2')

  | GRec (fix,ida,bl,ra1,ra2) as raw ->
      let ra1' = Array.Smart.map (subst_glob_constr env subst) ra1
      and ra2' = Array.Smart.map (subst_glob_constr env subst) ra2 in
      let bl' = Array.Smart.map
        (List.Smart.map (fun (na,k,obd,ty as dcl) ->
          let ty' = subst_glob_constr env subst ty in
          let obd' = Option.Smart.map (subst_glob_constr env subst) obd in
          if ty'==ty && obd'==obd then dcl else (na,k,obd',ty')))
        bl in
        if ra1' == ra1 && ra2' == ra2 && bl'==bl then raw else
          GRec (fix,ida,bl',ra1',ra2')

  | GHole (knd, naming, solve) as raw ->
    let nknd = match knd with
    | Evar_kinds.ImplicitArg (ref, i, b) ->
      let nref, _ = subst_global subst ref in
      if nref == ref then knd else Evar_kinds.ImplicitArg (nref, i, b)
    | _ -> knd
    in
    let nsolve = Option.Smart.map (Hook.get f_subst_genarg subst) solve in
    if nsolve == solve && nknd == knd then raw
    else GHole (nknd, naming, nsolve)

  | GCast (r1,k) as raw ->
      let r1' = subst_glob_constr env subst r1 in
      let k' = smartmap_cast_type (subst_glob_constr env subst) k in
      if r1' == r1 && k' == k then raw else GCast (r1',k')

  )

(* Utilities to transform kernel cases to simple pattern-matching problem *)

let simple_cases_matrix_of_branches ind brs =
  List.map (fun (i,n,b) ->
      let nal,c = it_destRLambda_or_LetIn_names n b in
      let mkPatVar na = DAst.make @@ PatVar na in
      let p = DAst.make @@ PatCstr ((ind,i+1),List.map mkPatVar nal,Anonymous) in
      let ids = List.map_filter Nameops.Name.to_option nal in
      CAst.make @@ (ids,[p],c))
    brs

let return_type_of_predicate ind nrealargs_tags pred =
  let nal,p = it_destRLambda_or_LetIn_names (nrealargs_tags@[false]) pred in
  (List.hd nal, Some (CAst.make (ind, List.tl nal))), Some p
