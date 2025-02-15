open! Prelude

type todo = string
[@@deriving
  show,
    yojson,
    hash,
    eq,
    visitors { variety = "reduce"; name = "todo_reduce" },
    visitors { variety = "mapreduce"; name = "todo_mapreduce" },
    visitors { variety = "map"; name = "todo_map" }]

type span = (Span.t[@visitors.opaque])
[@@deriving
  show,
    yojson,
    hash,
    compare,
    sexp,
    eq,
    visitors { variety = "reduce"; name = "span_reduce" },
    visitors { variety = "mapreduce"; name = "span_mapreduce" },
    visitors { variety = "map"; name = "span_map" }]

type concrete_ident = (Concrete_ident.t[@visitors.opaque])
[@@deriving
  show,
    yojson,
    hash,
    compare,
    sexp,
    hash,
    eq,
    visitors { variety = "reduce"; name = "concrete_ident_reduce" },
    visitors { variety = "mapreduce"; name = "concrete_ident_mapreduce" },
    visitors { variety = "map"; name = "concrete_ident_map" }]

type logical_op = And | Or

and primitive_ident = Deref | Cast | LogicalOp of logical_op
[@@deriving show, yojson, hash, compare, sexp, eq]

module Global_ident = struct
  module T = struct
    type t =
      [ `Concrete of concrete_ident
      | `Primitive of primitive_ident
      | `TupleType of int
      | `TupleCons of int
      | `TupleField of int * int
      | `Projector of [ `Concrete of concrete_ident | `TupleField of int * int ]
      ]
    [@@deriving show, yojson, compare, hash, sexp, eq]
  end

  module M = struct
    include Base.Comparator.Make (T)
    include T
  end

  include M
  module Map = Map.M (M)

  let of_name kind n = `Concrete (Concrete_ident.of_name kind n)

  let eq_name name (x : t) : bool =
    match x with `Concrete x -> Concrete_ident.eq_name name x | _ -> false

  let to_string : t -> string = [%show: t]
end

type global_ident = (Global_ident.t[@visitors.opaque])
[@@deriving
  show,
    yojson,
    hash,
    eq,
    visitors { variety = "reduce"; name = "global_ident_reduce" },
    visitors { variety = "mapreduce"; name = "global_ident_mapreduce" },
    visitors { variety = "map"; name = "global_ident_map" }]

type attr_kind =
  | Tool of { path : string; tokens : string }
  | DocComment of { kind : doc_comment_kind; body : string }

and attr = { kind : attr_kind; span : span }
and doc_comment_kind = DCKLine | DCKBlock

and attrs = attr list
[@@deriving
  show,
    yojson,
    hash,
    eq,
    visitors { variety = "reduce"; name = "attrs_reduce" },
    visitors { variety = "mapreduce"; name = "attrs_mapreduce" },
    visitors { variety = "map"; name = "attrs_map" }]

type local_ident = (Local_ident.t[@visitors.opaque])
[@@deriving
  show,
    yojson,
    hash,
    compare,
    sexp,
    eq,
    visitors { variety = "reduce"; name = "local_ident_reduce" },
    visitors { variety = "mapreduce"; name = "local_ident_mapreduce" },
    visitors { variety = "map"; name = "local_ident_map" }]

type size = S8 | S16 | S32 | S64 | S128 | SSize
[@@deriving show, yojson, hash, compare, eq]

let int_of_size = function
  | S8 -> Some 8
  | S16 -> Some 16
  | S32 -> Some 32
  | S64 -> Some 64
  | S128 -> Some 128
  | _ -> None

let string_of_size = int_of_size >> Option.map ~f:Int.to_string

type signedness = Signed | Unsigned
[@@deriving show, yojson, hash, compare, eq]

type int_kind = { size : size; signedness : signedness }
[@@deriving show, yojson, hash, compare, eq]

let show_int_kind { size; signedness } =
  (match signedness with Signed -> "i" | Unsigned -> "u")
  ^ (int_of_size size
    |> Option.map ~f:Int.to_string
    |> Option.value ~default:"size")

type float_kind = F32 | F64 [@@deriving show, yojson, hash, compare, eq]

let show_float_kind = function F32 -> "f32" | F64 -> "f64"

type literal =
  | String of string
  | Char of char
  | Int of {
      value : string;
      negative : bool;
      kind : (int_kind[@visitors.opaque]);
    }
  | Float of {
      value : string;
      negative : bool;
      kind : float_kind; [@visitors.opaque]
    }
  | Bool of bool
[@@deriving
  show,
    yojson,
    hash,
    eq,
    visitors { variety = "reduce"; name = "literal_reduce" },
    visitors { variety = "mapreduce"; name = "literal_mapreduce" },
    visitors { variety = "map"; name = "literal_map" }]

(* type 't spanned = { v : 't; span : span } [@@deriving show, yojson, hash, eq] *)

type 'mut_witness mutability = Mutable of 'mut_witness | Immutable
[@@deriving show, yojson, hash, eq]

module Make =
functor
  (F : Features.T)
  ->
  struct
    type borrow_kind = Shared | Unique | Mut of F.mutable_reference
    [@@deriving
      show,
        yojson,
        hash,
        eq,
        visitors { variety = "reduce"; name = "borrow_kind_reduce" },
        visitors { variety = "mapreduce"; name = "borrow_kind_mapreduce" },
        visitors { variety = "map"; name = "borrow_kind_map" }]

    type binding_mode =
      | ByValue
      | ByRef of (borrow_kind * (F.reference[@visitors.opaque]))
    [@@deriving
      show,
        yojson,
        hash,
        eq,
        visitors
          {
            variety = "reduce";
            name = "binding_mode_reduce";
            ancestors = [ "borrow_kind_reduce" ];
          },
        visitors
          {
            variety = "mapreduce";
            name = "binding_mode_mapreduce";
            ancestors = [ "borrow_kind_mapreduce" ];
          },
        visitors
          {
            variety = "map";
            name = "binding_mode_map";
            ancestors = [ "borrow_kind_map" ];
          }]

    module DefaultClasses = Features.DefaultClasses (F)

    (* TODO: generate those classes automatically *)
    class virtual ['self] default_reduce_features =
      object (self : 'self)
        inherit [_] VisitorsRuntime.reduce
        method visit_span _ (_ : span) = self#zero
        method visit_literal _ (_ : literal) = self#zero
      end

    class virtual ['self] default_map_features =
      object (_self : 'self)
        inherit [_] VisitorsRuntime.map
        method visit_literal : _ -> literal -> literal = Fn.const Fn.id
      end

    class virtual ['self] default_mapreduce_features =
      object (self : 'self)
        inherit [_] VisitorsRuntime.mapreduce
        method visit_literal : _ -> literal -> _ = fun _ x -> (x, self#zero)
      end

    type ty =
      | TBool
      | TChar
      | TInt of (int_kind[@visitors.opaque])
      | TFloat of (float_kind[@visitors.opaque])
      | TStr
      | TApp of { ident : global_ident; args : generic_value list }
      | TArray of { typ : ty; length : expr }
      | TSlice of { witness : F.slice; ty : ty }
      | TRawPointer of { witness : F.raw_pointer } (* todo *)
      | TRef of {
          witness : F.reference;
          region : todo;
          typ : ty;
          mut : (F.mutable_reference mutability[@visitors.opaque]);
        }
      | TParam of local_ident
      | TArrow of ty list * ty
      | TAssociatedType of { impl : impl_expr; item : concrete_ident }
      | TOpaque of concrete_ident

    and generic_value =
      | GLifetime of { lt : todo; witness : F.lifetime }
      | GType of ty
      | GConst of expr

    and impl_expr =
      | Concrete of trait_ref
      | LocalBound of { id : string }
      | Parent of { impl : impl_expr; trait : trait_ref }
      | Projection of {
          impl : impl_expr;
          trait : trait_ref;
          item : concrete_ident;
        }
      | ImplApp of { impl : impl_expr; args : impl_expr list }
      | Dyn of trait_ref
      | Builtin of trait_ref

    and trait_ref = { trait : concrete_ident; args : generic_value list }

    and pat' =
      | PWild
      | PAscription of { typ : ty; typ_span : span; pat : pat }
      | PConstruct of {
          name : global_ident;
          args : field_pat list;
          is_record : bool; (* are fields named? *)
          is_struct : bool; (* a struct has one constructor *)
        }
      (* An or-pattern, e.g. `p | q`.
         Invariant: `List.length subpats >= 2`. *)
      | POr of { subpats : pat list }
      | PArray of { args : pat list }
      | PDeref of { subpat : pat; witness : F.reference }
      | PConstant of { lit : literal }
      | PBinding of {
          mut : (F.mutable_variable mutability[@visitors.opaque]);
          mode : binding_mode;
          var : local_ident;
          typ : ty;
          subpat : (pat * F.as_pattern) option;
        }

    and pat = { p : pat'; span : span; typ : ty }
    and field_pat = { field : global_ident; pat : pat }

    and expr' =
      (* pure fragment *)
      | If of { cond : expr; then_ : expr; else_ : expr option }
      | App of {
          f : expr;
          args : expr list (* ; f_span: span *);
          generic_args : generic_value list;
        }
      | Literal of literal
      | Array of expr list
      | Construct of {
          constructor : global_ident;
          is_record : bool; (* are fields named? *)
          is_struct : bool; (* a struct has one constructor *)
          fields : (global_ident * expr) list;
          base : (expr * F.construct_base) option;
        }
      | Match of { scrutinee : expr; arms : arm list }
      | Let of {
          monadic : (supported_monads * F.monadic_binding) option;
          lhs : pat;
          rhs : expr;
          body : expr;
        }
      | Block of (expr * F.block)
        (* Corresponds to `{e}`: this is important for places *)
      | LocalVar of local_ident
      | GlobalVar of global_ident
      | Ascription of { e : expr; typ : ty }
      (* Macro *)
      | MacroInvokation of {
          macro : global_ident;
          args : string;
          witness : F.macro;
        }
      (* Mut *)
      | Assign of { lhs : lhs; e : expr; witness : F.mutable_variable }
      (* Loop *)
      | Loop of {
          body : expr;
          kind : loop_kind;
          state : loop_state option;
          label : string option;
          witness : F.loop;
        }
      (* ControlFlow *)
      | Break of { e : expr; label : string option; witness : F.break * F.loop }
      | Return of { e : expr; witness : F.early_exit }
      | QuestionMark of {
          e : expr;
          converted_typ : ty;
              (** [converted_typ] is the converted type: when you do [e?], a convertion might be inserted by Rust on the fly (e.g. [Something::from_residual(e)]) *)
          witness : F.question_mark;
        }
      | Continue of {
          e : (F.state_passing_loop * expr) option;
          label : string option;
          witness : F.continue * F.loop;
        }
      (* Mem *)
      | Borrow of { kind : borrow_kind; e : expr; witness : F.reference }
      (* Raw borrow *)
      | AddressOf of {
          mut : F.mutable_pointer mutability;
          e : expr;
          witness : F.raw_pointer;
        }
      | Closure of { params : pat list; body : expr; captures : expr list }
      | EffectAction of { action : F.monadic_action; argument : expr }

    and expr = { e : expr'; span : span; typ : ty }

    and supported_monads =
      | MException of ty
          (** a exception monad, which we use to handle early returns *)
      | MResult of ty  (** the [Result] monad *)
      | MOption  (** the [Option] monad *)

    and loop_kind =
      | UnconditionalLoop
      | ForLoop of { pat : pat; it : expr; witness : F.for_loop }
      | ForIndexLoop of {
          start : expr;
          end_ : expr;
          var : local_ident;
          var_typ : ty;
          witness : F.for_index_loop;
        }

    and loop_state = { init : expr; bpat : pat; witness : F.state_passing_loop }

    (* | WhileLoop of { *)
    (*     condition: expr; *)
    (*     witness : F.while_loop; *)
    (*   } *)

    (* TODO: LHS should be places or "compositions" of places, see [assignee expression] in https://doc.rust-lang.org/reference/expressions.html#place-expressions-and-value-expressions (issue #222) *)
    and lhs =
      | LhsLocalVar of { var : Local_ident.t; typ : ty }
      | LhsArbitraryExpr of { e : expr; witness : F.arbitrary_lhs }
      | LhsFieldAccessor of {
          e : lhs;
          typ : ty;
          (* TODO: change type (see #316) *)
          field : global_ident;
          witness : F.nontrivial_lhs;
        }
      | LhsArrayAccessor of {
          e : lhs;
          typ : ty;
          index : expr;
          witness : F.nontrivial_lhs;
        }

    (* OCaml + visitors is not happy with `pat`... hence `arm_pat`... *)
    and arm' = { arm_pat : pat; body : expr }

    and arm = { arm : arm'; span : span }
    [@@deriving
      show,
        yojson,
        hash,
        eq,
        visitors
          {
            variety = "reduce";
            name = "expr_reduce";
            ancestors =
              [
                "global_ident_reduce";
                "todo_reduce";
                "local_ident_reduce";
                "default_reduce_features";
                "DefaultClasses.default_reduce_features";
                "binding_mode_reduce";
                "span_reduce";
                "concrete_ident_reduce";
              ];
          },
        visitors
          {
            variety = "mapreduce";
            name = "expr_mapreduce";
            ancestors =
              [
                "global_ident_mapreduce";
                "todo_mapreduce";
                "local_ident_mapreduce";
                "default_mapreduce_features";
                "DefaultClasses.default_mapreduce_features";
                "binding_mode_mapreduce";
                "span_mapreduce";
                "concrete_ident_mapreduce";
              ];
          },
        visitors
          {
            variety = "map";
            name = "expr_map";
            ancestors =
              [
                "global_ident_map";
                "todo_map";
                "local_ident_map";
                "default_map_features";
                "DefaultClasses.default_map_features";
                "binding_mode_map";
                "span_map";
                "concrete_ident_map";
              ];
          }]

    type generic_param = {
      ident : local_ident;
      span : span;
      attrs : attrs;
      kind : generic_param_kind;
    }

    and generic_param_kind =
      | GPLifetime of { witness : (F.lifetime[@visitors.opaque]) }
      | GPType of { default : ty option }
      | GPConst of { typ : ty }

    and generic_constraint =
      | GCLifetime of todo * (F.lifetime[@visitors.opaque])
      | GCType of {
          bound : trait_ref;
              (* trait_ref is always applied with the type the trait implements.
                 For instance, `T: Clone` is actually `Clone<T> *)
          id : string;
        }
    [@@deriving
      show,
        yojson,
        hash,
        eq,
        visitors
          {
            variety = "reduce";
            name = "generic_constraint_reduce";
            ancestors = [ "expr_reduce" ];
          },
        visitors
          {
            variety = "mapreduce";
            name = "generic_constraint_mapreduce";
            ancestors = [ "expr_mapreduce" ];
          },
        visitors
          {
            variety = "map";
            name = "generic_constraint_map";
            ancestors = [ "expr_map" ];
          }]

    type param = { pat : pat; typ : ty; typ_span : span option; attrs : attrs }

    and generics = {
      params : generic_param list;
      constraints : generic_constraint list;
    }

    and variant = {
      name : concrete_ident;
      arguments : (concrete_ident * ty * attrs) list;
      is_record : bool;
      attrs : attrs;
    }

    and item' =
      (* Todo: topological sort, rec bundles *)
      | Fn of {
          name : concrete_ident;
          generics : generics;
          body : expr;
          params : param list;
        }
      | TyAlias of { name : concrete_ident; generics : generics; ty : ty }
      | Type of {
          name : concrete_ident;
          generics : generics;
          variants : variant list;
          is_struct : bool;
        }
      | IMacroInvokation of {
          macro : concrete_ident;
          argument : string;
          span : span;
          witness : F.macro;
        }
      | Trait of {
          name : concrete_ident;
          generics : generics;
          items : trait_item list;
        }
      | Impl of {
          generics : generics;
          self_ty : ty;
          of_trait : global_ident * generic_value list;
          items : impl_item list;
        }
      | Alias of { name : concrete_ident; item : concrete_ident }
          (** `Alias {name; item}` is basically a `use
              <item> as _;` where `name` is the renamed ident. *)
      | Use of {
          path : string list;
          is_external : bool;
          rename : string option;
        }
      | HaxError of string
      | NotImplementedYet

    and item = { v : item'; span : span; ident : concrete_ident; attrs : attrs }

    and impl_item' =
      | IIType of ty
      | IIFn of { body : expr; params : param list }

    and impl_item = {
      ii_span : span;
      ii_generics : generics;
      ii_v : impl_item';
      ii_ident : concrete_ident;
      ii_attrs : attrs;
    }

    and trait_item' = TIType of trait_ref list | TIFn of ty

    and trait_item = {
      (* TODO: why do I need to prefix by `ti_` here? I guess visitors fail or something *)
      ti_span : span;
      ti_generics : generics;
      ti_v : trait_item';
      ti_ident : concrete_ident;
      ti_attrs : attrs;
    }
    [@@deriving
      show,
        yojson,
        hash,
        eq,
        visitors
          {
            variety = "reduce";
            name = "item_reduce";
            ancestors =
              [ "generic_constraint_reduce"; "expr_reduce"; "attrs_reduce" ];
          },
        visitors
          {
            variety = "mapreduce";
            name = "item_mapreduce";
            ancestors =
              [
                "generic_constraint_mapreduce";
                "expr_mapreduce";
                "attrs_mapreduce";
              ];
          },
        visitors
          {
            variety = "map";
            name = "item_map";
            ancestors = [ "generic_constraint_map"; "expr_map"; "attrs_map" ];
          }]

    type modul = item list

    let make_hax_error_item (span : span) (ident : Concrete_ident.t)
        (s : string) : item =
      { v = HaxError s; span; ident; attrs = [] }

    module F = F
  end

module type T = sig
  type expr [@@deriving show, yojson]
  type item' [@@deriving show, yojson]

  type item = {
    v : item';
    span : span;
    ident : Concrete_ident.t;
    attrs : attrs;
  }
  [@@deriving show, yojson]

  val make_hax_error_item : span -> Concrete_ident.t -> string -> item
end

module Rust = Make (Features.Rust)
module Full = Make (Features.Full)
