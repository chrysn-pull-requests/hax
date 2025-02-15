open! Prelude

module Imported = struct
  type def_id = { krate : string; path : disambiguated_def_path_item list }

  and disambiguated_def_path_item = {
    data : def_path_item;
    disambiguator : int;
  }

  and def_path_item =
    | CrateRoot
    | Impl
    | ForeignMod
    | Use
    | GlobalAsm
    | ClosureExpr
    | Ctor
    | AnonConst
    | ImplTrait
    | ImplTraitAssocTy
    | TypeNs of string
    | ValueNs of string
    | MacroNs of string
    | LifetimeNs of string
  [@@deriving show, yojson, compare, sexp, eq, hash]

  let of_def_path_item : Types.def_path_item -> def_path_item = function
    | CrateRoot -> CrateRoot
    | Impl -> Impl
    | ForeignMod -> ForeignMod
    | Use -> Use
    | GlobalAsm -> GlobalAsm
    | ClosureExpr -> ClosureExpr
    | Ctor -> Ctor
    | AnonConst -> AnonConst
    | ImplTrait -> ImplTrait
    | ImplTraitAssocTy -> ImplTraitAssocTy
    | TypeNs s -> TypeNs s
    | ValueNs s -> ValueNs s
    | MacroNs s -> MacroNs s
    | LifetimeNs s -> LifetimeNs s

  let of_disambiguated_def_path_item :
      Types.disambiguated_def_path_item -> disambiguated_def_path_item =
   fun Types.{ data; disambiguator } ->
    {
      data = of_def_path_item data;
      disambiguator = MyInt64.to_int_exn disambiguator;
    }

  let of_def_id Types.{ krate; path; _ } =
    { krate; path = List.map ~f:of_disambiguated_def_path_item path }

  let parent { krate; path; _ } = { krate; path = List.drop_last_exn path }

  let drop_ctor { krate; path; _ } =
    {
      krate;
      path =
        (match (List.drop_last path, List.last path) with
        | Some path, Some { data = Ctor; _ } -> path
        | _ -> path);
    }

  let map_path_strings ~(f : string -> string) (did : def_id) : def_id =
    let f : def_path_item -> def_path_item = function
      | TypeNs s -> TypeNs (f s)
      | ValueNs s -> ValueNs (f s)
      | MacroNs s -> MacroNs (f s)
      | LifetimeNs s -> LifetimeNs (f s)
      | other -> other
    in
    let f x = { x with data = f x.data } in
    { did with path = List.map ~f did.path }
end

module ImplInfos = struct
  type t = Types.impl_infos
  (** Contains the informations `Generics`, `Trait` (if not an
  inherent type), `Type` and `Bounds` for an `impl` block
  `impl<Generics> [Trait for] Type where Bounds {}` *)
end

(** Stateful store that maps `def_id`s to implementation informations
(which trait is implemented? for which type? under which constraints?) *)
module ImplInfoStore : sig
  val init : (Types.def_id * ImplInfos.t) list -> unit
  val find : Imported.def_id -> ImplInfos.t option

  val has_impl_prefix :
    Imported.def_id ->
    (ImplInfos.t
    * Imported.disambiguated_def_path_item list
    * Imported.disambiguated_def_path_item list)
    option
  (** If a `def_id` `did` points to an item that is an `impl` or a
      child of an `impl`, `has_impl_prefix did` returns `Some (infos,
      before, after)`. `infos` is of type `ImplInfos.t` (cf its
      documentation). `before` and `after` are the partial paths
      before and after the `impl` in `did`'s path. Note that if
      `after` is empty, that means `did` points to the `impl`
      itself. *)
end = struct
  let state : (Imported.def_id, ImplInfos.t) Hashtbl.t option ref = ref None

  module T = struct
    type t = Imported.def_id [@@deriving show, yojson, compare, sexp, eq, hash]
  end

  let init impl_infos =
    state :=
      impl_infos
      |> List.map ~f:(map_fst Imported.of_def_id)
      |> Hashtbl.of_alist_exn (module T)
      |> Option.some

  let get_state () =
    match !state with
    | None -> failwith "ImplInfoStore was not initialized"
    | Some state -> state

  let find k = Hashtbl.find (get_state ()) k

  let has_impl_prefix (did : Imported.def_id) =
    let krate = did.krate in
    let is_impl : Imported.def_path_item -> bool = function
      | Impl -> true
      | _ -> false
    in
    let before, rest =
      List.split_while did.path ~f:(fun x -> is_impl x.data |> not)
    in
    let* impl_chunk = List.hd rest in
    let* after = List.tl rest in
    let path = before @ [ impl_chunk ] in
    let did : Imported.def_id = { krate; path } in
    match find did with
    | Some infos -> Some (infos, before, after)
    | None -> failwith "invariant error"
end

module Kind = struct
  type t =
    | Type
    | Value
    | Lifetime
    | Constructor of { is_struct : bool }
    | Field
    | Macro
    | Trait
    | Impl
    | AssociatedItem of t
  [@@deriving show, yojson, compare, sexp, eq, hash]

  let of_def_path_item : Imported.def_path_item -> t option = function
    | TypeNs _ -> Some Type
    | ValueNs _ -> Some Value
    | LifetimeNs _ -> Some Lifetime
    | _ -> None
end

module View = struct
  module T = struct
    type view = { crate : string; path : string list; definition : string }
  end

  include T

  module Utils = struct
    let string_of_def_path_item : Imported.def_path_item -> string option =
      function
      | TypeNs s | ValueNs s | MacroNs s | LifetimeNs s -> Some s
      | Impl -> Some "impl"
      | AnonConst -> Some "anon_const"
      | _ -> None

    let string_of_disambiguated_def_path_item
        (x : Imported.disambiguated_def_path_item) : string option =
      let n = x.disambiguator in
      string_of_def_path_item x.data
      |> Option.map ~f:(fun base ->
             match n with
             | 0 -> (
                 match String.rsplit2 ~on:'_' base with
                 | Some (_, "") -> base ^ "_"
                 | Some (_, r) when Option.is_some @@ Stdlib.int_of_string_opt r
                   ->
                     base ^ "_" (* potentially conflicting name, adding a `_` *)
                 | _ -> base)
             | _ -> base ^ "_" ^ Int.to_string n)
  end

  open Utils

  let simple_ty_to_string ~(namespace : Imported.def_id) :
      Types.ty -> string option =
    let escape =
      let re = Re.Pcre.regexp "_((?:e_)*)of_" in
      let f group = "_e_" ^ Re.Group.get group 1 ^ "of_" in
      Re.replace ~all:true re ~f
    in
    let adt def_id =
      let* () =
        [%equal: Imported.def_id]
          (Imported.(of_def_id >> parent) def_id)
          namespace
        |> some_if_true
      in
      let* last = List.last def_id.path in
      let* () = some_if_true Int64.(last.disambiguator = zero) in
      last.data |> Imported.of_def_path_item |> string_of_def_path_item
      |> Option.map ~f:escape
    in
    let arity0 =
      Option.map ~f:escape << function
      | Types.Bool -> Some "bool"
      | Char -> Some "char"
      | Str -> Some "str"
      | Never -> Some "never"
      | Int Isize -> Some "isize"
      | Int I8 -> Some "i8"
      | Int I16 -> Some "i16"
      | Int I32 -> Some "i32"
      | Int I64 -> Some "i64"
      | Int I128 -> Some "i128"
      | Uint Usize -> Some "usize"
      | Uint U8 -> Some "u8"
      | Uint U16 -> Some "u16"
      | Uint U32 -> Some "u32"
      | Uint U64 -> Some "u64"
      | Uint U128 -> Some "u128"
      | Float F32 -> Some "f32"
      | Float F64 -> Some "f64"
      | Tuple [] -> Some "unit"
      | Adt { def_id; generic_args = [] } -> adt def_id
      | _ -> None
    in
    let apply left right = left ^ "_of_" ^ right in
    let rec arity1 = function
      | Types.Slice sub -> arity1 sub |> Option.map ~f:(apply "slice")
      | Ref (_, sub, _) -> arity1 sub |> Option.map ~f:(apply "ref")
      | Adt { def_id; generic_args = [ Type arg ] } ->
          let* adt = adt def_id in
          let* arg = arity1 arg in
          Some (apply adt arg)
      | Tuple l ->
          let* l = List.map ~f:arity0 l |> Option.all in
          Some ("tuple_" ^ String.concat ~sep:"_" l)
      | otherwise -> arity0 otherwise
    in
    arity1

  let rec to_view (def_id : Imported.def_id) : view =
    let impl_infos = ImplInfoStore.has_impl_prefix def_id in
    let def_id =
      match impl_infos with
      (* inherent impl: we don't want the `impl` keyword to appear *)
      | Some ({ trait_ref = Some _; _ }, lpath, rpath)
        when not (List.is_empty rpath) ->
          (* this basically amounts exactly to dropping the `impl` chunk *)
          Imported.{ krate = def_id.krate; path = lpath @ rpath }
      | _ -> def_id
    in
    let path, definition =
      List.filter_map ~f:string_of_disambiguated_def_path_item def_id.path
      |> last_init |> Option.value_exn
    in
    let sep = "__" in
    let subst = String.substr_replace_all ~pattern:sep ~with_:(sep ^ "_") in
    let fake_path, real_path =
      (* Detects paths of nested items *)
      List.rev def_id.path |> List.tl_exn
      |> List.split_while ~f:(fun (x : Imported.disambiguated_def_path_item) ->
             [%matches? Imported.ValueNs _ | Imported.Impl] x.data)
      |> List.rev *** List.rev
    in
    let subst_dpi =
      string_of_disambiguated_def_path_item >> Option.map ~f:subst
    in
    let definition = subst definition in
    let fake_path, definition =
      let fake_path' = List.filter_map ~f:subst_dpi fake_path in
      match impl_infos with
      | Some
          ( { trait_ref = None; generics = { params = []; _ }; typ; _ },
            before,
            _ )
        when [%matches? [ Imported.{ data = Impl; _ } ]] fake_path ->
          let namespace = Imported.{ krate = def_id.krate; path = before } in
          simple_ty_to_string ~namespace typ
          |> Option.map ~f:(fun typ -> ([ "impl"; typ ], definition))
          |> Option.value ~default:(fake_path', definition)
      | Some
          ( {
              trait_ref = Some { def_id = trait; generic_args = [ _self ] };
              generics = { params = []; _ };
              typ;
              _;
            },
            before,
            [] ) ->
          let namespace = Imported.{ krate = def_id.krate; path = before } in
          (let* () =
             some_if_true
             @@ [%equal: Imported.def_id]
                  (Imported.(of_def_id >> parent) trait)
                  namespace
           in
           let* typ = simple_ty_to_string ~namespace typ in
           let* trait = List.last trait.path in
           let* trait =
             Imported.of_def_path_item trait.data |> string_of_def_path_item
           in
           let sep = "_for_" in
           let trait =
             let re = Re.Pcre.regexp "_((?:e_)*)for_" in
             let f group = "_e_" ^ Re.Group.get group 1 ^ "for_" in
             Re.replace ~all:true re ~f trait
           in
           Some ("impl_" ^ trait ^ sep ^ typ))
          |> Option.value ~default:definition
          |> tup2 fake_path'
      | _ -> (fake_path', definition)
    in
    let real_path = List.filter_map ~f:subst_dpi real_path in
    if List.is_empty fake_path then { crate = def_id.krate; path; definition }
    else
      let definition = String.concat ~sep (fake_path @ [ definition ]) in
      { crate = def_id.krate; path = real_path; definition }

  and to_definition_name x = (to_view x).definition
end

module T = struct
  type t = { def_id : Imported.def_id; kind : Kind.t }
  [@@deriving show, yojson, sexp]

  (* [kind] is really a metadata, it is not relevant, `def_id`s are unique *)
  let equal x y = [%equal: Imported.def_id] x.def_id y.def_id
  let compare x y = [%compare: Imported.def_id] x.def_id y.def_id
  let of_def_id kind def_id = { def_id = Imported.of_def_id def_id; kind }
  let hash x = [%hash: Imported.def_id] x.def_id
  let hash_fold_t s x = Imported.hash_fold_def_id s x.def_id

  type name = Concrete_ident_generated.name

  let of_name k = Concrete_ident_generated.def_id_of >> of_def_id k

  let eq_name name id =
    let of_name =
      Concrete_ident_generated.def_id_of name |> Imported.of_def_id
    in
    [%equal: Imported.def_id] of_name id.def_id
end

include T
include View.T
include (val Comparator.make ~compare ~sexp_of_t)

include Concrete_ident_sig.Make (struct
  type t_ = t
  type view_ = view
end)

module MakeViewAPI (NP : NAME_POLICY) : VIEW_API = struct
  type t = T.t

  let pp fmt = show >> Stdlib.Format.pp_print_string fmt
  let is_reserved_word : string -> bool = Hash_set.mem NP.reserved_words

  let rename_definition (_path : string list) (name : string) (kind : Kind.t)
      _type_name =
    (* let path, name = *)
    (*   match kind with *)
    (*   | Constructor { is_struct = false } -> *)
    (*       let path, type_name = (List.drop_last_exn path, List.last_exn path) in *)
    (*       (path, type_name ^ "_" ^ name) *)
    (*   | _ -> (path, name) *)
    (* in *)
    let prefixes = [ "t"; "C"; "v"; "f"; "i" ] in
    let escape s =
      match String.lsplit2 ~on:'_' s with
      | Some (prefix, _) when List.mem ~equal:String.equal prefixes prefix ->
          String.prefix prefix 1 ^ s
      | _ -> s
    in
    match kind with
    | Type | Trait -> "t_" ^ name
    | Value | Impl ->
        if start_uppercase name || is_reserved_word name then "v_" ^ name
        else escape name
    | Constructor _ ->
        if start_lowercase name || is_reserved_word name then "C_" ^ name
        else escape name
    | Field | AssociatedItem _ -> (
        match Stdlib.int_of_string_opt name with
        | Some _ -> NP.index_field_transform name
        (* | _ -> "f_" ^ Option.value_exn type_name ^ "_" ^ name *)
        | _ -> "f_" ^ name)
    | Lifetime | Macro -> escape name

  let rec to_view ({ def_id; kind } : t) : view =
    let def_id = Imported.drop_ctor def_id in
    let View.{ crate; path; definition } = View.to_view def_id in
    let type_name =
      try
        { def_id = Imported.parent def_id; kind = Type }
        |> to_definition_name
        |> String.chop_prefix_exn ~prefix:"t_"
        |> Option.some
      with _ -> None
    in
    let path, definition =
      match kind with
      | Constructor { is_struct = false } ->
          ( List.drop_last_exn path,
            Option.value_exn type_name ^ "_" ^ definition )
      | Field when List.last path |> [%equal: string option] type_name ->
          (List.drop_last_exn path, definition)
      | AssociatedItem _ -> (List.drop_last_exn path, definition)
      | _ -> (path, definition)
    in
    let definition = rename_definition path definition kind type_name in
    View.{ crate; path; definition }

  and to_definition_name (x : t) : string = (to_view x).definition

  let to_crate_name (x : t) : string = (to_view x).crate

  let to_namespace x =
    let View.{ crate; path; _ } = to_view x in
    (crate, path)

  let show x =
    to_view x
    |> (fun View.{ crate; path; definition } ->
         crate :: (path @ [ definition ]))
    |> String.concat ~sep:"::"

  let local_ident (li : Local_ident.t) =
    if Local_ident.is_final li then li.name
    else
      to_definition_name
        {
          def_id =
            {
              krate = "dummy_for_local_name";
              path = [ { data = ValueNs li.name; disambiguator = 0 } ];
            };
          kind = Value;
        }
end

let to_debug_string = T.show

let map_path_strings ~(f : string -> string) (cid : t) : t =
  { cid with def_id = Imported.map_path_strings ~f cid.def_id }

module DefaultNamePolicy = struct
  let reserved_words = Hash_set.create (module String)
  let index_field_transform = Fn.id
end

let matches_namespace (ns : Types.namespace) (did : t) : bool =
  let did = did.def_id in
  let path : string option list =
    Some did.krate
    :: (did.path
       |> List.map ~f:(fun (x : Imported.disambiguated_def_path_item) ->
              View.Utils.string_of_def_path_item x.data))
  in
  let rec aux (pattern : Types.namespace_chunk list) (path : string option list)
      =
    match (pattern, path) with
    | [], [] -> true
    | Exact x :: pattern, Some y :: path ->
        [%equal: string] x y && aux pattern path
    | Glob One :: pattern, _ :: path -> aux pattern path
    | Glob Many :: pattern, [] -> aux pattern []
    | Glob Many :: pattern', _ :: path' ->
        aux pattern' path || aux pattern path'
    | _ -> false
  in
  aux ns.chunks path

module Create = struct
  let parent (id : t) : t = { id with def_id = Imported.parent id.def_id }

  let fresh_module ~from =
    let len x = List.length x.def_id.path in
    let compare x y = len x - len y in
    let id = List.min_elt ~compare from |> Option.value_exn in
    let parent = parent id in
    {
      kind = Kind.Value;
      def_id =
        {
          parent.def_id with
          path =
            parent.def_id.path
            @ [
                {
                  data = TypeNs "rec_bundle";
                  disambiguator = [%hash: t list] from;
                };
              ];
        };
    }

  let move_under ~new_parent old =
    let new_parent = new_parent.def_id in
    {
      kind = old.kind;
      def_id =
        {
          new_parent with
          path = new_parent.path @ [ List.last_exn old.def_id.path ];
        };
    }
end

module DefaultViewAPI = MakeViewAPI (DefaultNamePolicy)
include DefaultViewAPI
