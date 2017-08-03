module Canvas exposing (..)

-- builtins
import Dict

-- lib
import Task
import Dom
import Mouse
import List.Extra

-- dark
import Defaults
import Types exposing (..)
import Util exposing (deMaybe)
import Graph as G

-------------------
-- Focus
-------------------
maybeFocusEntry : Cursor -> Cursor -> Cmd Msg
maybeFocusEntry oldc c =
  if not (entryVisible oldc) && (entryVisible c) then
    focusEntry
  else
    Cmd.none

focusEntry : Cmd Msg
focusEntry = Dom.focus Defaults.entryID |> Task.attempt FocusResult

focusRepl : Cmd Msg
focusRepl = Cmd.none -- Dom.focus Defaults.replID |> Task.attempt FocusResult

unfocusRepl : Cmd Msg
unfocusRepl = Dom.blur Defaults.replID |> Task.attempt FocusResult

-------------------
-- Dragging
-------------------
updateDragPosition : Pos -> Offset -> ID -> NodeDict -> NodeDict
updateDragPosition pos off (ID id) nodes =
  Dict.update id (Maybe.map (\n -> {n | pos = {x=pos.x+off.x, y=pos.y+off.y}})) nodes



-------------------
-- Positioning
-------------------
nextPosition : Pos -> Pos
nextPosition {x, y} =
  if x > 900 then
    {x=100, y=y+100}
  else
    {x=x+100, y=y}

findOffset : Pos -> Mouse.Position -> Offset
findOffset pos mpos =
 {x=pos.x - mpos.x, y= pos.y - mpos.y, offsetCheck=1}

paramOffset : Node -> String -> Pos
paramOffset node param =
  let
    index = deMaybe (List.Extra.elemIndex param node.parameters)
  in
    {x=index*10, y=-2}

------------------
-- cursor stuff
----------------

isSelected : Model -> Node -> Bool
isSelected m n =
  case m.cursor of
    Filling node _ _ -> n == node
    _ -> False

entryVisible : Cursor -> Bool
entryVisible cursor =
  case cursor of
    Deselected -> False
    Dragging _ -> False
    _ -> True

getCursorID : Cursor -> Maybe ID
getCursorID c =
  case c of
    Dragging id -> Just id
    Filling node _ _ -> Just node.id
    _ -> Nothing

selectNextNode : Model -> (Pos -> Pos  -> Bool) -> Cursor
selectNextNode m cond =
  -- if we're currently in a node, follow the direction. For now, pick
  -- the nearest node to it, that it's connected to, that's roughly in
  -- that direction.
  case m.cursor of
    Filling n _ _ ->
      let other =
          G.connectedNodes m n
            -- that are above us
            |> List.filter (\o -> cond n.pos o.pos)
            -- the nearest to us
            |> List.sortBy (\other -> G.distance other n)
            |> List.head
      in
        case other of
          Nothing -> m.cursor
          Just node -> selectNode m node
    _ -> m.cursor




selectNode : Model -> Node -> Cursor
selectNode m selected =
  let hole = G.findHole m selected
      pos = case hole of
              ResultHole n -> {x=n.pos.x+100,y=n.pos.y+100}
              ParamHole n _ i -> {x=n.pos.x-100+(i*100), y=n.pos.y-100}
  in
    Filling selected hole pos
