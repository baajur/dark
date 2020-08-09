open Core
open Libexecution

(* space, path, modifier *)
type event_desc = string * string * string [@@deriving show, yojson]

type event_record =
  string * string * string * Types.RuntimeT.time * Analysis_types.traceid
[@@deriving show, yojson]

type four_oh_four = event_record [@@deriving show, yojson]

val get_handlers_for_canvas : Uuidm.t -> event_desc list

(* We store a set of events for each host. The events may or may not
 * belong to a toplevel. We provide a list in advance so that they can
 * be partitioned effectively. Returns the DB-assigned event timestamp. *)
val store_event :
     trace_id:Uuidm.t
  -> canvas_id:Uuidm.t
  -> ?timestamp:Time.t
  -> event_desc
  -> Types.RuntimeT.dval
  -> Types.RuntimeT.time

val load_event_for_trace :
     canvas_id:Uuidm.t
  -> Uuidm.t
  -> (string * Types.RuntimeT.time * Types.RuntimeT.dval) option

val load_events :
     ?limit:int
  -> canvas_id:Uuidm.t
  -> event_desc
  -> (string * Uuidm.t * Types.RuntimeT.time * Types.RuntimeT.dval) list

val load_event_ids : canvas_id:Uuidm.t -> event_desc -> (Uuidm.t * string) list

val list_events :
     limit:
       [`All | `After of Types.RuntimeT.time | `Before of Types.RuntimeT.time]
  -> canvas_id:Uuidm.t
  -> unit
  -> event_record list

val clear_all_events : canvas_id:Uuidm.t -> unit -> unit

val get_404s :
     limit:
       [`All | `After of Types.RuntimeT.time | `Before of Types.RuntimeT.time]
  -> Uuidm.t
  -> four_oh_four list

type trim_events_action =
  | Count
  | Delete

type trim_events_canvases =
  | All
  | JustOne of string

val action_to_string : trim_events_action -> string

val db_fn :
     trim_events_action
  -> params:Db.param list
  -> ?result:Db.result
  -> name:string
  -> ?subject:string
  -> string
  -> int

val trim_events_for_canvas :
     span:Libcommon.Telemetry.Span.t
  -> action:trim_events_action
  -> Uuidm.t
  -> string
  -> int
  -> int

val trim_events_for_handler :
     span:Libcommon.Telemetry.Span.t
  -> action:trim_events_action
  -> limit:int
  -> module_:string
  -> path:string
  -> modifier:string
  -> canvas_name:string
  -> canvas_id:Uuidm.t
  -> int
