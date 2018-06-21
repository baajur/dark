open Core_kernel

(* This one is interesting.
 *
 * There is a bug in ppx_bin_prot (aka [@deriving bin_io]) that this
 * works around.
 *
 * https://github.com/janestreet/bin_prot/issues/18
 *
 * The problem is that the signatures generated by bin_io are wrong. The
 * functions created have a signature with `'a`, but they should have
 * `'a. 'a`.
 *
 * This only occurs because we use both `string or_blank` and `'a
 * or_blank` in the same type defintion.
 *
 * To fix this, we generated the code using the bin_io ppx, then copied
 * it in here and fixed the signatures. Sadly, this required us to copy
 * a bunch of definitions in here too :-/
 *
 * Line 8 below refers to the 'a or_blank definition.
 *)


type id = int [@@deriving eq, compare, show, yojson, sexp, bin_io]
type 'a or_blank = Blank of id
                 | Filled of id * 'a
                 | Flagged of id * (string or_blank) * int * ('a or_blank) * ('a or_blank)
                 [@@deriving eq, compare, show, yojson, sexp]


let bin_shape_or_blank =
  let _group =
    Bin_prot.Shape.group
      (Bin_prot.Shape.Location.of_string "lib/types.ml:8:0")
      [((Bin_prot.Shape.Tid.of_string "or_blank"),
         [Bin_prot.Shape.Vid.of_string "a"],
         (Bin_prot.Shape.variant
            [("Blank", [bin_shape_id]);
            ("Filled",
              [bin_shape_id;
              Bin_prot.Shape.var
                (Bin_prot.Shape.Location.of_string "lib/types.ml:9:34")
                (Bin_prot.Shape.Vid.of_string "a")]);
            ("Flagged",
              [bin_shape_id;
              (Bin_prot.Shape.rec_app
                 (Bin_prot.Shape.Tid.of_string "or_blank"))
                [bin_shape_string];
              bin_shape_int;
              (Bin_prot.Shape.rec_app
                 (Bin_prot.Shape.Tid.of_string "or_blank"))
                [Bin_prot.Shape.var
                   (Bin_prot.Shape.Location.of_string "lib/types.ml:10:62")
                   (Bin_prot.Shape.Vid.of_string "a")];
              (Bin_prot.Shape.rec_app
                 (Bin_prot.Shape.Tid.of_string "or_blank"))
                [Bin_prot.Shape.var
                   (Bin_prot.Shape.Location.of_string "lib/types.ml:10:78")
                   (Bin_prot.Shape.Vid.of_string "a")]])]))] in
  fun a ->
    (Bin_prot.Shape.top_app _group (Bin_prot.Shape.Tid.of_string "or_blank"))
      [a]
let _ = bin_shape_or_blank
let rec bin_size_or_blank : 'a. 'a Bin_prot.Size.sizer -> 'a or_blank -> int =
  fun _size_of_a ->
  function
  | Blank v1 -> let size = 1 in Pervasives.(+) size (bin_size_id v1)
  | Filled (v1, v2) ->
      let size = 1 in
      let size = Pervasives.(+) size (bin_size_id v1) in
      Pervasives.(+) size (_size_of_a v2)
  | Flagged (v1, v2, v3, v4, v5) ->
      let size = 1 in
      let size = Pervasives.(+) size (bin_size_id v1) in
      let size = Pervasives.(+) size (bin_size_or_blank bin_size_string v2) in
      let size = Pervasives.(+) size (bin_size_int v3) in
      let size = Pervasives.(+) size (bin_size_or_blank _size_of_a v4) in
      Pervasives.(+) size (bin_size_or_blank _size_of_a v5)
let _ = bin_size_or_blank
let rec bin_write_or_blank : 'a. 'a Bin_prot.Write.writer -> _ ->
  pos: _-> 'a or_blank -> _ =
  fun _write_a buf ~pos ->
  function
  | Blank v1 ->
      let pos = Bin_prot.Write.bin_write_int_8bit buf ~pos 0 in
      bin_write_id buf ~pos v1
  | Filled (v1, v2) ->
      let pos = Bin_prot.Write.bin_write_int_8bit buf ~pos 1 in
      let pos = bin_write_id buf ~pos v1 in _write_a buf ~pos v2
  | Flagged (v1, v2, v3, v4, v5) ->
      let pos = Bin_prot.Write.bin_write_int_8bit buf ~pos 2 in
      let pos = bin_write_id buf ~pos v1 in
      let pos = (bin_write_or_blank bin_write_string) buf ~pos v2 in
      let pos = bin_write_int buf ~pos v3 in
      let pos = (bin_write_or_blank _write_a) buf ~pos v4 in
      (bin_write_or_blank _write_a) buf ~pos v5
let _ = bin_write_or_blank
let bin_writer_or_blank bin_writer_a =
  {
    Bin_prot.Type_class.size =
      (fun v -> bin_size_or_blank bin_writer_a.Bin_prot.Type_class.size v);
    write =
      (fun v -> bin_write_or_blank bin_writer_a.Bin_prot.Type_class.write v)
  }
let _ = bin_writer_or_blank
let rec __bin_read_or_blank__ _of__a _buf ~pos_ref  _vint =
  Bin_prot.Common.raise_variant_wrong_type "lib/types.ml.or_blank" (!pos_ref)
and bin_read_or_blank : 'a. 'a Bin_prot.Read.reader -> _ -> pos_ref: _
  -> 'a or_blank =
  fun _of__a buf ~pos_ref ->
  match Bin_prot.Read.bin_read_int_8bit buf ~pos_ref with
  | 0 -> let arg_1 = bin_read_id buf ~pos_ref in Blank arg_1
  | 1 ->
      let arg_1 = bin_read_id buf ~pos_ref in
      let arg_2 = _of__a buf ~pos_ref in Filled (arg_1, arg_2)
  | 2 ->
      let arg_1 = bin_read_id buf ~pos_ref in
      let arg_2 = (bin_read_or_blank bin_read_string) buf ~pos_ref in
      let arg_3 = bin_read_int buf ~pos_ref in
      let arg_4 = (bin_read_or_blank _of__a) buf ~pos_ref in
      let arg_5 = (bin_read_or_blank _of__a) buf ~pos_ref in
      Flagged (arg_1, arg_2, arg_3, arg_4, arg_5)
  | _ ->
      Bin_prot.Common.raise_read_error
        (Bin_prot.Common.ReadError.Sum_tag "lib/types.ml.or_blank")
        (!pos_ref)
let _ = __bin_read_or_blank__
and _ = bin_read_or_blank
let bin_reader_or_blank bin_reader_a =
  {
    Bin_prot.Type_class.read =
      (fun buf ->
         fun ~pos_ref ->
           (bin_read_or_blank bin_reader_a.Bin_prot.Type_class.read) buf
             ~pos_ref);
    vtag_read =
      (fun buf ->
         fun ~pos_ref ->
           fun vtag ->
             (__bin_read_or_blank__ bin_reader_a.Bin_prot.Type_class.read)
               buf ~pos_ref vtag)
  }
let _ = bin_reader_or_blank
let bin_or_blank bin_a =
  {
    Bin_prot.Type_class.writer =
      (bin_writer_or_blank bin_a.Bin_prot.Type_class.writer);
    reader = (bin_reader_or_blank bin_a.Bin_prot.Type_class.reader);
    shape = (bin_shape_or_blank bin_a.Bin_prot.Type_class.shape)
  }
let _ = bin_or_blank

