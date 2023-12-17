(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Utility functions that help to build Unif expressions *)

(* Author: Piotr Polesiuk, 2023 *)

open Common

module StrSet = Set.Make(String)

(** Make polymorphic function with given type parameters *)
let rec make_tfun tvs body =
  match tvs with
  | [] -> body
  | x :: tvs ->
    { T.pos  = body.T.pos;
      T.data = T.ETFun(x, make_tfun tvs body)
    }

(** Make function polymorphic in implicit parameters *)
let rec make_ifun ims body =
  match ims with
  | [] -> body
  | (_, x, tp) :: ims ->
    { T.pos  = body.T.pos;
      T.data = T.EFn(x, tp, make_ifun ims body)
    }

let rec make_tapp e tps =
  match tps with
  | [] -> e
  | tp :: tps ->
    let e =
      { T.pos  = e.T.pos;
        T.data = T.ETApp(e, tp)
      }
    in
    make_tapp e tps

let generalize env ims e tp =
  let tvs =
    List.fold_left
      (fun tvs (_, _, itp) -> T.Type.collect_uvars itp tvs)
      (T.Type.uvars tp)
      ims
    |> Fun.flip T.UVar.Set.diff (Env.uvars env)
    |> T.UVar.Set.elements
    |> List.map T.UVar.fix
  in
  let sch =
    { T.sch_tvars    = tvs
    ; T.sch_implicit = List.map (fun (name, _, tp) -> (name, tp)) ims
    ; T.sch_body     = tp
    }
  in
  (make_tfun tvs (make_ifun ims e), sch)

(** The main instantiation function. [nset] parameter is a set of names
  currently instantiated, used to avoid infinite loops, e.g., in
  [`n : {`n : _} -> _] *)
let rec instantiate_loop ~nset env e (sch : T.scheme) =
  let guess_type sub tv =
    let tp = Env.fresh_uvar env (T.TVar.kind tv) in
    (T.Subst.add_type sub tv tp, tp)
  in
  let (sub, tps) =
    List.fold_left_map guess_type T.Subst.empty sch.sch_tvars in
  let e = make_tapp e tps in
  let e =
    List.fold_left (instantiate_implicit ~nset env sub) e sch.sch_implicit
  in
  (e, T.Type.subst sub sch.sch_body)

and instantiate_implicit ~nset env sub (e : T.expr) (name, tp) =
  if StrSet.mem name nset then
    Error.fatal (Error.looping_implicit ~pos:e.pos name)
  else
    let nset = StrSet.add name nset in
    let tp = T.Type.subst sub tp in
    begin match Env.lookup_implicit env name with
    | Some(x, sch, on_use) ->
      on_use e.pos;
      let arg = { T.pos = e.pos; T.data = T.EVar x } in
      let (arg, arg_tp) = instantiate_loop ~nset env arg sch in
      if Subtyping.subtype env arg_tp tp then
        { T.pos = e.pos; T.data = T.EApp(e, arg) }
      else
        Error.fatal
          (Error.implicit_type_mismatch ~pos:e.pos ~env name arg_tp tp)
    | None ->
      Error.fatal (Error.unbound_implicit ~pos:e.pos name)
    end

let instantiate env e sch =
  instantiate_loop ~nset:StrSet.empty env e sch