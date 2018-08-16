module Entry exposing (..)

-- builtins
import Task
-- import Result exposing (Result)
-- import Set

-- lib
import Dom
-- import Result.Extra as RE
-- import Maybe.Extra as ME
import List.Extra as LE

-- dark
import Types exposing (..)
import Prelude  exposing (..)
import Util
import DB
import Defaults
import Analysis
import Viewport
import AST
import Toplevel as TL
import Runtime as RT
import Refactor
import Pointer as P
import SpecHeaders
import Blank as B
import Autocomplete as AC


createFindSpace : Model -> Modification
createFindSpace m = Enter (Creating (Viewport.toAbsolute m Defaults.initialVPos))

---------------------
-- Focus
---------------------

focusEntry : Model -> Cmd Msg
focusEntry m =
  case unwrapCursorState m.cursorState of
    Entering _ ->
      Dom.focus Defaults.entryID |> Task.attempt FocusEntry
    _ ->
      Cmd.none


newHandlerSpec : () -> HandlerSpec
newHandlerSpec _ = { module_ = B.new ()
                   , name = B.new ()
                   , modifier = B.new ()
                   , types = { input = B.new ()
                             , output = B.new ()
                             }
                   }

createFunction : Model -> FnName -> Maybe Expr
createFunction m name =
  let blanks count = LE.initialize count (\_ -> B.new ())
      fn = m.complete.functions
           |> List.filter (\fn -> fn.name == name)
           |> List.head
  in
    case fn of
      Just function ->
        let r = if function.returnTipe == TOption then Rail else NoRail in
        Just <|
          B.newF (FnCall name (blanks (List.length function.parameters)) r)
      Nothing -> Nothing

submitOmniAction : Model -> Pos -> OmniAction -> Modification
submitOmniAction m pos action =
  case action of
    NewDB dbname ->
      let next = gid ()
          tlid = gtlid ()
      in
          RPC ([ CreateDB tlid pos dbname
               , AddDBCol tlid next (gid ())
               ] , FocusExact tlid next)
    NewHTTPHandler ->
      let next = gid ()
          tlid = gtlid ()
          spec = newHandlerSpec ()
          handler = { ast = B.new()
                    , spec = { spec | module_ = B.newF "HTTP"
                                    , name = Blank next}
                    }
      in
          RPC ([ SetHandler tlid pos handler
               ] , FocusExact tlid next)
    NewEventSpace name ->
      let next = gid ()
          tlid = gtlid ()
          spec = newHandlerSpec ()
          handler = { ast = B.new()
                    , spec = { spec | module_ = B.newF name
                                    , name = Blank next}
                    }
      in
          RPC ([ SetHandler tlid pos handler
               ] , FocusExact tlid next)
    NewHTTPRoute route ->
      let next = gid ()
          tlid = gtlid ()
          spec = newHandlerSpec ()
          handler = { ast = B.new()
                    , spec = { spec | name = B.newF route
                                    , module_ = B.newF "HTTP"
                                    , modifier = Blank next}
                    }
      in
          RPC ([ SetHandler tlid pos handler
               ] , FocusExact tlid next)

-- Assumes PD is within AST. Returns (new AST, new Expr)
replaceExpr : Model -> TLID -> Expr -> Expr -> NextAction -> String ->
  (Expr, Expr)
replaceExpr m tlid ast old_ action value =
  let id = B.toID old_
      target = Just (tlid, PExpr old_)
      (old, new) =
        -- assign thread to variable
        if Util.reExactly "=[a-zA-Z].*" value
        then
          case AST.threadAncestors id ast of
            -- turn the current thread into a let-assignment to this
            -- name, and close the thread
            (F _ (Thread _) as thread) :: _ ->
              let bindName = value
                             |> String.dropLeft 1
                             |> String.trim
              in
                ( thread
                , B.newF (
                    Let
                      (B.newF bindName)
                      (AST.closeThreads thread)
                      (B.new ())))

            _ ->
              (old_, old_)

        -- field access
        else if String.endsWith "." value
        then
          ( old_
          , B.newF
              (FieldAccess
                (B.newF (Variable (String.dropRight 1 value)))
                (B.new ())))

        -- variables
        else if List.member value (Analysis.varnamesFor m target)
        then (old_, B.newF (Variable value))

        -- parsed exprs
        else
          ( old_
          , parseAst m value
            |> Maybe.withDefault old_)


      newAst =
        case action of
          StartThread ->
            ast
            |> AST.replace (PExpr old) (PExpr new)
            |> AST.wrapInThread (B.toID new)
          _ ->
            ast
            |> AST.replace (PExpr old) (PExpr new)
            |> AST.maybeExtendThreadAt (B.toID new)
            |> AST.maybeExtendListLiteralAt (PExpr new)
  in
  (newAst, new)

parseAst : Model -> String -> Maybe Expr
parseAst m str =
  let eid = gid ()
      b1 = B.new ()
      b2 = B.new ()
      b3 = B.new ()
      firstWord = String.split " " str in
  case firstWord of
    ["if"] ->
      Just <| F eid (If b1 b2 b3)
    ["let"] ->
      Just <| F eid (Let b1 b2 b3)
    ["lambda"] ->
      Just <| F eid (Lambda [B.newF "var"] b2)
    [""] ->
      Just b1
    ["[]"] ->
      Just <| F eid (ListLiteral [B.new ()])
    ["["] ->
      Just <| F eid (ListLiteral [B.new ()])
    ["{}"] ->
      Just <| F eid (ObjectLiteral [(B.new (), B.new ())])
    ["{"] ->
      Just <| F eid (ObjectLiteral [(B.new (), B.new ())])
    _ ->
      if not (RT.isLiteral str)
      then createFunction m str
      else Just <| F eid (Value str)

type NextAction = StartThread | StayHere | GotoNext
submit : Model -> EntryCursor -> NextAction -> Modification
submit m cursor action =
  -- TODO: replace parsing with taking the autocomplete suggestion and
  -- doing what we're told with it.
  let value = AC.getValue m.complete in
  case cursor of
    Creating pos ->
      let tlid = gtlid ()
          threadIt expr =
            case action of
              StartThread ->
                B.newF (Thread [expr, B.new ()])
              GotoNext ->
                expr
              StayHere ->
                expr
          wrapExpr expr =
            let newAst = threadIt expr
                focus = newAst
                        |> AST.allData
                        |> List.filter P.isBlank
                        |> List.head
                        |> Maybe.map P.toID
                        |> Maybe.map (FocusExact tlid)
                        |> Maybe.withDefault (FocusNext tlid Nothing)
                -- NB: these pos magic numbers position the tl body
                -- where the click was
                op = SetHandler tlid { pos | x = pos.x - 17
                                           , y = pos.y - 70
                                     }
                                     { ast = newAst
                                     , spec = newHandlerSpec ()
                                     }
            in RPC ([op], focus)
      in

      -- field access
      if String.endsWith "." value
      then
        wrapExpr <|
          B.newF
            (FieldAccess
               (B.newF (Variable (String.dropRight 1 value)))
               (B.new ()))

      -- varnames
      else if List.member value (Analysis.varnamesFor m Nothing)
      then wrapExpr <| B.newF (Variable value)

      -- start new AST
      else
        case parseAst m value of
          Nothing -> NoChange
          Just v -> wrapExpr v

    Filling tlid id ->
      let tl = TL.getTL m tlid
          pd = TL.findExn tl id
          result = validate tl pd value
      in
      if String.length value < 1
      then NoChange
      else if result /= Nothing
      then
        DisplayAndReportError <| deMaybe "checked above" result
      else
      let maybeH = TL.asHandler tl
          db = TL.asDB tl

          wrap ops next =
            let wasEditing = P.isBlank pd |> not
                focus = if wasEditing && action == StayHere
                        then
                          case next of
                            Nothing -> FocusSame
                            Just nextID -> FocusExact tl.id nextID
                        else
                          FocusNext tl.id next
            in

            RPC (ops, focus)
          wrapID ops = wrap ops (Just id)
          wrapNew ops new = wrap ops (Just (P.toID new))
          save newtl next =
            if newtl == tl
            then NoChange
            else
              case newtl.data of
                TLHandler h ->
                  wrapNew [SetHandler tlid tl.pos h] next
                TLFunc f ->
                  wrapNew [SetFunction f] next
                TLDB _ -> impossible ("no vars in DBs", tl.data)

          saveH h next =
            save ({ tl | data = TLHandler h }) next

          saveAst ast next =
            case tl.data of
              TLHandler h ->
                saveH { h | ast = ast} next
              TLFunc f ->
                save ({ tl | data = TLFunc { f | ast = ast}}) next
              TLDB _ -> impossible ("no vars in DBs", tl.data)

          replace new =
            tl
            |> TL.replace pd new
            |> \tl -> save tl new
      in
      case pd of
        PDBColType ct ->
          if B.asF ct == Just value
          then Select tlid (Just id)
          else if B.isBlank ct
          then
            wrapID [ SetDBColType tlid id value
                   , AddDBCol tlid (gid ()) (gid ())]
          else
            wrapID [ ChangeDBColType tlid id value]

        PDBColName cn ->
          if B.asF cn == Just value
          then Select tlid (Just id)
          else if DB.hasCol (db |> deMaybe "db") value
          then DisplayError ("Can't have two DB fields with the same name: " ++ value)
          else if B.isBlank cn
          then
            wrapID [SetDBColName tlid id value]
          else
            wrapID [ChangeDBColName tlid id value]
        PVarBind _ ->
          replace (PVarBind (B.newF value))
        PEventName _ ->
          replace (PEventName (B.newF value))
        PEventModifier _ ->
          replace (PEventModifier (B.newF value))
        PEventSpace _ ->
          let h = deMaybe "maybeH - eventspace" maybeH
              new = B.newF value
              replacement = SpecHeaders.replaceEventSpace id new h.spec
              replacement2 =
                if SpecHeaders.visibleModifier replacement
                then replacement
                else
                  SpecHeaders.replaceEventModifier
                   (B.toID h.spec.modifier)
                   (B.newF "_")
                   replacement
          in
          saveH {h | spec = replacement2 } (PEventSpace new)
        PField _ ->
          let ast =
                case tl.data of
                  TLHandler h -> h.ast
                  TLFunc f -> f.ast
                  TLDB _ -> impossible ("No fields in DBs", tl.data)
              parent = AST.parentOf id ast
          in
          -- Nested field?
          if String.endsWith "." value
          then
            let fieldname = String.dropRight 1 value
                -- wrap the field access with another field access
                -- get the parent ID from the old AST, cause it has the
                -- blank. Then get the parent structure from the new ID
                wrapped =
                  case parent of
                    F id (FieldAccess lhs rhs) ->
                      B.newF (
                        FieldAccess
                          (F id (FieldAccess lhs (B.newF fieldname)))
                          (B.new ()))
                    _ -> impossible ("should be a field", parent)
                new = PExpr wrapped
                replacement = TL.replace (PExpr parent) new tl in
            save replacement new

          else if action == StartThread
          then
            -- Starting a new thread from the field
            let replacement = AST.replace pd (PField (B.newF value)) ast
                newAst = AST.wrapInThread (B.toID parent) replacement
            in
            saveAst newAst (PExpr parent)
          else
            -- Changing a field
            replace (PField (B.newF value))

        PKey k ->
          let new = PKey (B.newF value)
              ast =
                case tl.data of
                  TLHandler h -> h.ast
                  TLFunc f -> f.ast
                  TLDB _ -> impossible ("No fields in DBs", tl.data)
          in
          ast
          |> AST.replace pd new
          |> AST.maybeExtendObjectLiteralAt new
          |> \ast -> saveAst ast new
        PExpr e ->
          case tl.data of
            TLHandler h ->
              let (newast, newexpr) =
                    replaceExpr m tl.id h.ast e action value
              in
              saveAst newast (PExpr newexpr)

            TLFunc f ->
              let (newast, newexpr) =
                    replaceExpr m tl.id f.ast e action value
              in
              saveAst newast (PExpr newexpr)

            TLDB db ->
              case db.activeMigration of
                Nothing -> NoChange
                Just am ->
                  if List.member pd (AST.allData am.rollback)
                  then
                    let (newast, newexpr) =
                          replaceExpr m tl.id am.rollback e action value
                    in
                    wrapNew [SetExpr tl.id id newast] (PExpr newexpr)
                  else if List.member pd (AST.allData am.rollforward)
                  then
                    let (newast, newexpr) =
                          replaceExpr m tl.id am.rollforward e action value
                    in
                    wrapNew [SetExpr tl.id id newast] (PExpr newexpr)
                  else
                    NoChange
        PDarkType _ ->
          let specType =
                case value of
                  "String" -> DTString
                  "Any" -> DTAny
                  "Int" -> DTInt
                  "Empty" -> DTEmpty
                  "{" -> DTObj [(B.new (), B.new ())]
                  _ -> todo "disallowed value"
          in
          replace (PDarkType (B.newF specType))

        PDarkTypeField _ ->
          replace (PDarkTypeField (B.newF value))
        PFFMsg _ ->
          replace (PFFMsg (B.newF value))
        PFnName _ ->
          let newPD = PFnName (B.newF value)
              newTL = TL.replace pd newPD tl
              changedNames =
                let old = TL.asUserFunction tl |> deMaybe "old userFn"
                    new = TL.asUserFunction newTL |> deMaybe "new userFn"
                in Refactor.renameFunction m old new
          in
          wrapNew
            (SetFunction (TL.asUserFunction newTL |> deMaybe "must be function")
            :: changedNames)
            newPD
        PParamName _ ->
          replace (PParamName (B.newF value))
        PParamTipe _ ->
          replace (PParamTipe (B.newF (RT.str2tipe value)))



validate : Toplevel -> PointerData -> String -> Maybe String
validate tl pd value =
  let v pattern name =
        if Util.reExactly pattern value
        then Nothing
        else Just (name ++ " must match /" ++ pattern ++ "/")
  in
  case pd of
    PDBColType ct ->
      v "\\[?[A-Z]\\w+\\]?" "DB type"
    PDBColName cn ->
      if value == "id"
      then Just "id's are automatic and implicit, no need to add them"
      else v "\\w+" "DB column name"
    PVarBind _ ->
      v "[a-zA-Z_][a-zA-Z0-9_]*" "variable name"
    PEventName _ ->
      let urlSafeCharacters = "[-a-zA-Z0-9@:%_+.~#?&/=]"
          http = "/(" ++ urlSafeCharacters ++ "*)" -- preceding slash
          event = urlSafeCharacters ++ "+" -- at least one
      in
      if TL.isHTTPHandler tl
      then v http "route name"
      else v event "event name"
    PEventModifier _ ->
      if TL.isHTTPHandler tl
      then v "[A-Z]+" "verb"
      else v "[a-zA-Z_][\\sa-zA-Z0-9_]*" "event modifier"
    PEventSpace _ ->
      v "[A-Z_]+" "event space"
    PField _ ->
      v ".+" "fieldname"
    PKey _ ->
      v ".+" "key"
    PExpr e ->
      Nothing -- done elsewhere
    PDarkType _ ->
      v "(String|Int|Any|Empty|{)" "type"
    PDarkTypeField _ ->
      Nothing
    PFFMsg _ ->
      Nothing
    PFnName _ ->
      Nothing
    PParamName _ ->
      Nothing
    PParamTipe _ ->
      v "[A-Z][a-z]*" "param type"
