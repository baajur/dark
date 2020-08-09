open Core_kernel
open Libexecution
open Types
module RTT = Types.RuntimeT
module Telemetry = Libcommon.Telemetry
module Log = Libcommon.Log

(* ------------------------- *)
(* External *)
(* ------------------------- *)

let store ~canvas_id ~trace_id tlid args =
  Db.run
    ~name:"stored_function_arguments.store"
    "INSERT INTO function_arguments
     (canvas_id, trace_id, tlid, timestamp, arguments_json)
     VALUES ($1, $2, $3, CURRENT_TIMESTAMP, $4)"
    ~params:[Uuid canvas_id; Uuid trace_id; ID tlid; RoundtrippableDvalmap args]


let load_for_analysis ~canvas_id tlid (trace_id : Uuidm.t) :
    (Analysis_types.input_vars * RTT.time) option =
  (* We need to alias the subquery (here aliased as `q`) because Postgres
   * requires inner SELECTs to be aliased. *)
  Db.fetch
    ~name:"stored_function_arguments.load_for_analysis"
    "SELECT arguments_json, timestamp FROM (
      SELECT DISTINCT ON (trace_id) trace_id, timestamp, arguments_json
      FROM function_arguments
      WHERE canvas_id = $1 AND tlid = $2 AND trace_id = $3
      ORDER BY trace_id, timestamp DESC
      ) AS q
      ORDER BY timestamp DESC
      LIMIT 1"
    ~params:[Db.Uuid canvas_id; Db.ID tlid; Db.Uuid trace_id]
  |> List.hd
  |> Option.map ~f:(function
         | [args; timestamp] ->
             ( args
               |> Dval.of_internal_roundtrippable_v0
               |> Dval.to_dval_pairs_exn
             , Util.date_of_isostring timestamp )
         | _ ->
             Exception.internal
               "Bad format for stored_functions.load_for_analysis")


let load_traceids ~(canvas_id : Uuidm.t) (tlid : Types.tlid) : Uuidm.t list =
  (* We need to alias the subquery (here aliased as `q`) because Postgres
   * requires inner SELECTs to be aliased. *)
  Db.fetch
    ~name:"stored_function_arguments.load_traceids"
    "SELECT trace_id FROM (
      SELECT DISTINCT ON (trace_id) trace_id, timestamp
      FROM function_arguments
      WHERE canvas_id = $1 AND tlid = $2
      ORDER BY trace_id, timestamp DESC
      ) AS q
      ORDER BY timestamp DESC
      LIMIT 10"
    ~params:[Db.Uuid canvas_id; Db.ID tlid]
  |> List.map ~f:(function
         | [trace_id] ->
             Util.uuid_of_string trace_id
         | _ ->
             Exception.internal
               "Bad DB format for stored_functions.load_for_analysis")


type trim_arguments_action = Stored_event.trim_events_action

let trim_arguments_for_handler
    (span : Libcommon.Telemetry.Span.t)
    (action : trim_arguments_action)
    ~(limit : int)
    ~(canvas_name : string)
    ~(tlid : string)
    (canvas_id : Uuidm.t) : int =
  let action_str = Stored_event.action_to_string action in
  Telemetry.with_span
    span
    "trim_arguments_for_handler"
    ~attrs:
      [ ("limit", `Int limit)
      ; ("canvas_id", `String (canvas_id |> Uuidm.to_string))
      ; ("canvas_name", `String canvas_name)
      ; ("tlid", `String tlid)
      ; ("action", `String action_str) ]
    (fun span ->
      let limit =
        (* Since we're deleting traces not in the main table, if the main table
         * has a lot of traces we might be in trouble, so cut it down a bit. *)
        let count =
          Db.fetch_count
            ~name:"count stored_events_v2"
            "SELECT COUNT(*) FROM stored_events_v2 WHERE canvas_id = $1 and tlid = $2"
            ~params:[Db.Uuid canvas_id; Db.String tlid]
        in
        if count > 1000000
        then limit / 100
        else if count > 100000
        then limit / 10
        else limit
      in

      let count =
        try
          (Stored_event.db_fn action)
            ~name:"gc_function_arguments"
            (Printf.sprintf
               "WITH event_ids AS (
                  SELECT trace_id
                  FROM stored_events_v2
                  WHERE canvas_id = $1
                    AND tlid = $2),
              to_delete AS (
                SELECT trace_id
                  FROM function_arguments
                  WHERE canvas_id = $1
                    AND tlid = $2
                  LIMIT $3)
              %s FROM function_arguments
                WHERE canvas_id = $1
                  AND tlid = $2
                  AND trace_id IN (SELECT trace_id FROM event_ids)
                  AND trace_id IN (SELECT trace_id FROM to_delete);"
               action_str)
            ~params:[Db.Uuid canvas_id; Db.String tlid; Db.Int limit]
        with Exception.DarkException e ->
          Log.erroR
            "db error"
            ~params:
              [ ( "err"
                , e
                  |> Exception.exception_data_to_yojson
                  |> Yojson.Safe.to_string ) ] ;
          Exception.reraise (Exception.DarkException e)
      in
      Telemetry.Span.set_attr span "row_count" (`Int count) ;
      count)


(** trim_arguments_for_canvas is like trim_arguments_for_canvas but for a single canvas.
 *
 * All the comments and warnings there apply. Please read them. *)
let trim_arguments_for_canvas
    (span : Libcommon.Telemetry.Span.t)
    (action : trim_arguments_action)
    ~(limit : int)
    ~(canvas_name : string)
    (canvas_id : Uuidm.t) : int =
  Telemetry.with_span span "trim_arguments_for_canvas" (fun span ->
      let handlers =
        Telemetry.with_span
          span
          "get_user_functions_for_canvas"
          ~attrs:[("canvas_name", `String canvas_name)]
          (fun span ->
            ( try
                Db.fetch
                  ~name:"get_user_functions_for_gc"
                  "SELECT tlid
                   FROM toplevel_oplists
                   WHERE canvas_id = $1
                   AND tipe = 'user_function';"
                  ~params:[Db.Uuid canvas_id]
              with Exception.DarkException e ->
                Log.erroR
                  "db error"
                  ~params:
                    [ ( "err"
                      , e
                        |> Exception.exception_data_to_yojson
                        |> Yojson.Safe.to_string ) ] ;
                Exception.reraise (Exception.DarkException e) )
            (* List.hd_exn - we're only returning one field from this query *)
            |> List.map ~f:(fun tlid -> tlid |> List.hd_exn))
      in
      let row_count : int =
        handlers
        |> List.map ~f:(fun tlid ->
               trim_arguments_for_handler
                 span
                 action
                 ~tlid
                 ~canvas_name
                 ~limit
                 canvas_id)
        |> Tc.List.sum
      in
      Telemetry.Span.set_attrs
        span
        [ ("handler_count", `Int (handlers |> List.length))
        ; ("row_count", `Int row_count)
        ; ("canvas_name", `String canvas_name)
        ; ("canvas_id", `String (canvas_id |> Uuidm.to_string)) ] ;
      row_count)
