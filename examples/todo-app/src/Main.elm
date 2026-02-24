port module Main exposing (main)

import Browser
import ConcurrentTask exposing (ConcurrentTask)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput, onSubmit)
import IndexedDb as Idb
import Json.Decode as Decode
import Json.Encode as Encode
import Time



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }



-- PORTS


port send : Decode.Value -> Cmd msg


port receive : (Decode.Value -> msg) -> Sub msg



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ ConcurrentTask.onProgress
            { send = send
            , receive = receive
            , onProgress = OnProgress
            }
            model.tasks
        , Time.every 1000 Tick
        ]



-- INDEXES


{-| Index on the "timestamp" field for time-range queries.
Exercises: defineIndex, withIndex
-}
byTimestamp : Idb.Index
byTimestamp =
    Idb.defineIndex "by_timestamp" "timestamp"


{-| Index on the "action" field for filtering by action type.
Exercises: defineIndex, withIndex
-}
byAction : Idb.Index
byAction =
    Idb.defineIndex "by_action" "action"



-- STORES


{-| InlineKey store — key extracted from the value's "id" field.
Exercises: defineStore, withKeyPath
-}
todosStore : Idb.Store Idb.InlineKey
todosStore =
    Idb.defineStore "todos"
        |> Idb.withKeyPath "id"


{-| ExplicitKey store — key provided separately on every write.
Exercises: defineStore (bare)
-}
settingsStore : Idb.Store Idb.ExplicitKey
settingsStore =
    Idb.defineStore "settings"


{-| GeneratedKey store with secondary indexes — key auto-generated,
queryable by timestamp or action.
Exercises: defineStore, withAutoIncrement, withIndex
-}
eventsStore : Idb.Store Idb.GeneratedKey
eventsStore =
    Idb.defineStore "events"
        |> Idb.withAutoIncrement
        |> Idb.withIndex byTimestamp
        |> Idb.withIndex byAction


{-| Schema with all three store types, now including indexes.
Exercises: schema, withStore (x3)
-}
appSchema : Idb.Schema
appSchema =
    Idb.schema "todoapp" 3
        |> Idb.withStore todosStore
        |> Idb.withStore settingsStore
        |> Idb.withStore eventsStore



-- TYPES


type alias Todo =
    { id : Int
    , text : String
    , done : Bool
    }


type alias Event =
    { action : String
    , timestamp : Time.Posix
    }


type EventFilter
    = AllEvents
    | RecentEvents
    | ByAction String



-- ENCODERS / DECODERS


todoDecoder : Decode.Decoder Todo
todoDecoder =
    Decode.map3 Todo
        (Decode.field "id" Decode.int)
        (Decode.field "text" Decode.string)
        (Decode.field "done" Decode.bool)


encodeTodo : Todo -> Encode.Value
encodeTodo todo =
    Encode.object
        [ ( "id", Encode.int todo.id )
        , ( "text", Encode.string todo.text )
        , ( "done", Encode.bool todo.done )
        ]


eventDecoder : Decode.Decoder Event
eventDecoder =
    Decode.map2 Event
        (Decode.field "action" Decode.string)
        (Decode.field "timestamp" Decode.int
            |> Decode.map Time.millisToPosix
        )


encodeEvent : String -> Time.Posix -> Encode.Value
encodeEvent action time =
    Encode.object
        [ ( "action", Encode.string action )
        , ( "timestamp", Encode.int (Time.posixToMillis time) )
        ]



-- TASKS


type alias AppData =
    { db : Idb.Db
    , todos : List Todo
    , theme : String
    , eventCount : Int
    , todoKeys : List Idb.Key
    }


{-| Open the database, seed default settings, then load all data.
Exercises: open, addAt, onError chaining
-}
loadApp : ConcurrentTask Idb.Error AppData
loadApp =
    Idb.open appSchema
        |> ConcurrentTask.andThen initDefaults
        |> ConcurrentTask.andThen loadData


{-| Try to insert a default theme setting. Silently ignores AlreadyExists
on subsequent loads. Exercises: addAt
-}
initDefaults : Idb.Db -> ConcurrentTask Idb.Error Idb.Db
initDefaults db =
    Idb.addAt db settingsStore (Idb.StringKey "theme") (Encode.string "light")
        |> ConcurrentTask.onError (\_ -> ConcurrentTask.succeed ())
        |> ConcurrentTask.return db


{-| Load all data concurrently.
Exercises: getAll, get, count (parallel via map3)
-}
loadData : Idb.Db -> ConcurrentTask Idb.Error AppData
loadData db =
    ConcurrentTask.map3
        (\todoPairs theme eventCount ->
            { db = db
            , todos = List.map Tuple.second todoPairs
            , theme = theme |> Maybe.withDefault "light"
            , eventCount = eventCount
            , todoKeys = List.map Tuple.first todoPairs
            }
        )
        (Idb.getAll db todosStore todoDecoder)
        (Idb.get db settingsStore (Idb.StringKey "theme") Decode.string)
        (Idb.count db eventsStore)


{-| Insert a new todo and log the event concurrently.
Exercises: add, insert (parallel via map2)
-}
addTodoTask : Idb.Db -> Todo -> Time.Posix -> ConcurrentTask Idb.Error ()
addTodoTask db todo now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.add db todosStore (encodeTodo todo))
        (Idb.insert db eventsStore (encodeEvent "add_todo" now))


{-| Upsert a toggled todo and log the event. Exercises: put, insert
-}
toggleTodoTask : Idb.Db -> Todo -> Time.Posix -> ConcurrentTask Idb.Error ()
toggleTodoTask db todo now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.put db todosStore (encodeTodo todo))
        (Idb.insert db eventsStore (encodeEvent "toggle_todo" now))


{-| Delete a single todo by key and log it. Exercises: delete, insert
-}
deleteTodoTask : Idb.Db -> Int -> Time.Posix -> ConcurrentTask Idb.Error ()
deleteTodoTask db id now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.delete db todosStore (Idb.IntKey id))
        (Idb.insert db eventsStore (encodeEvent "delete_todo" now))


{-| Delete all completed todos in one transaction. Exercises: deleteMany
-}
deleteCompletedTask : Idb.Db -> List Idb.Key -> Time.Posix -> ConcurrentTask Idb.Error ()
deleteCompletedTask db keys now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.deleteMany db todosStore keys)
        (Idb.insert db eventsStore (encodeEvent "delete_completed" now))


{-| Toggle the theme setting and log it. Exercises: putAt, insert
-}
toggleThemeTask : Idb.Db -> String -> Time.Posix -> ConcurrentTask Idb.Error ()
toggleThemeTask db newTheme now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.putAt db settingsStore (Idb.StringKey "theme") (Encode.string newTheme))
        (Idb.insert db eventsStore (encodeEvent "toggle_theme" now))


{-| Batch-insert sample data into all three stores, then reload.
Exercises: putMany, putManyAt, insertMany (parallel via batch), andThenDo
-}
addSampleDataTask : Idb.Db -> Time.Posix -> ConcurrentTask Idb.Error AppData
addSampleDataTask db now =
    ConcurrentTask.batch
        [ Idb.putMany db todosStore sampleTodoValues
        , Idb.putManyAt db settingsStore sampleSettingPairs
        , Idb.insertMany db eventsStore (sampleEventValues now)
            |> ConcurrentTask.map (\_ -> ())
        ]
        |> ConcurrentTask.andThenDo (loadData db)


{-| Clear all todos and log it. Exercises: clear, insert
-}
clearTodosTask : Idb.Db -> Time.Posix -> ConcurrentTask Idb.Error ()
clearTodosTask db now =
    ConcurrentTask.map2 (\_ _ -> ())
        (Idb.clear db todosStore)
        (Idb.insert db eventsStore (encodeEvent "clear_todos" now))


{-| Delete the entire database. Exercises: deleteDatabase
-}
resetDatabaseTask : Idb.Db -> ConcurrentTask Idb.Error ()
resetDatabaseTask db =
    Idb.deleteDatabase db


{-| Query events within a time range via the timestamp index.
Exercises: getByIndex, between, PosixKey
-}
queryRecentEventsTask : Idb.Db -> Time.Posix -> ConcurrentTask Idb.Error (List Event)
queryRecentEventsTask db now =
    let
        fiveMinutesAgo =
            Time.millisToPosix (Time.posixToMillis now - 5 * 60 * 1000)
    in
    Idb.getByIndex db
        eventsStore
        byTimestamp
        (Idb.between (Idb.PosixKey fiveMinutesAgo) (Idb.PosixKey now))
        eventDecoder
        |> ConcurrentTask.map (List.map Tuple.second)


{-| Query events by action type via the action index.
Exercises: getByIndex, only, StringKey
-}
queryEventsByActionTask : Idb.Db -> String -> ConcurrentTask Idb.Error (List Event)
queryEventsByActionTask db action =
    Idb.getByIndex db
        eventsStore
        byAction
        (Idb.only (Idb.StringKey action))
        eventDecoder
        |> ConcurrentTask.map (List.map Tuple.second)


{-| Query all events (no filter, just get everything).
Exercises: getAll
-}
queryAllEventsTask : Idb.Db -> ConcurrentTask Idb.Error (List Event)
queryAllEventsTask db =
    Idb.getAll db eventsStore eventDecoder
        |> ConcurrentTask.map (List.map Tuple.second)



-- SAMPLE DATA


sampleTodoValues : List Encode.Value
sampleTodoValues =
    [ encodeTodo { id = 100, text = "Learn Elm", done = True }
    , encodeTodo { id = 101, text = "Build an app with IndexedDB", done = False }
    , encodeTodo { id = 102, text = "Deploy to production", done = False }
    ]


sampleSettingPairs : List ( Idb.Key, Encode.Value )
sampleSettingPairs =
    [ ( Idb.StringKey "language", Encode.string "en" )
    , ( Idb.StringKey "pageSize", Encode.string "20" )
    ]


sampleEventValues : Time.Posix -> List Encode.Value
sampleEventValues now =
    [ encodeEvent "sample_data_loaded" now
    , encodeEvent "settings_initialized" now
    ]



-- MODEL


type alias Model =
    { tasks : ConcurrentTask.Pool Msg
    , db : Maybe Idb.Db
    , todos : List Todo
    , nextId : Int
    , input : String
    , theme : String
    , eventCount : Int
    , todoKeys : List Idb.Key
    , events : List Event
    , eventFilter : EventFilter
    , now : Time.Posix
    , status : Status
    }


type Status
    = Loading
    | Ready
    | Error String


init : () -> ( Model, Cmd Msg )
init _ =
    let
        ( tasks, cmd ) =
            ConcurrentTask.attempt
                { send = send
                , pool = ConcurrentTask.pool
                , onComplete = GotLoad
                }
                loadApp
    in
    ( { tasks = tasks
      , db = Nothing
      , todos = []
      , nextId = 1
      , input = ""
      , theme = "light"
      , eventCount = 0
      , todoKeys = []
      , events = []
      , eventFilter = AllEvents
      , now = Time.millisToPosix 0
      , status = Loading
      }
    , cmd
    )



-- UPDATE


type Msg
    = UpdateInput String
    | AddTodo
    | ToggleTodo Int
    | DeleteTodo Int
    | DeleteCompleted
    | ToggleTheme
    | AddSampleData
    | ClearTodos
    | ResetDatabase
    | SetEventFilter EventFilter
    | RefreshEvents
    | Tick Time.Posix
    | GotLoad (ConcurrentTask.Response Idb.Error AppData)
    | GotWrite (ConcurrentTask.Response Idb.Error ())
    | GotReset (ConcurrentTask.Response Idb.Error ())
    | GotEvents (ConcurrentTask.Response Idb.Error (List Event))
    | OnProgress ( ConcurrentTask.Pool Msg, Cmd Msg )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick now ->
            ( { model | now = now }, Cmd.none )

        UpdateInput text ->
            ( { model | input = text }, Cmd.none )

        AddTodo ->
            case model.db of
                Just db ->
                    if String.trim model.input /= "" then
                        let
                            todo =
                                { id = model.nextId
                                , text = String.trim model.input
                                , done = False
                                }

                            ( tasks, cmd ) =
                                ConcurrentTask.attempt
                                    { send = send
                                    , pool = model.tasks
                                    , onComplete = GotWrite
                                    }
                                    (addTodoTask db todo model.now)
                        in
                        ( { model
                            | tasks = tasks
                            , todos = model.todos ++ [ todo ]
                            , nextId = model.nextId + 1
                            , input = ""
                            , eventCount = model.eventCount + 1
                          }
                        , cmd
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ToggleTodo id ->
            case model.db of
                Just db ->
                    let
                        updatedTodos =
                            List.map
                                (\t ->
                                    if t.id == id then
                                        { t | done = not t.done }

                                    else
                                        t
                                )
                                model.todos

                        maybeTodo =
                            List.filter (\t -> t.id == id) updatedTodos
                                |> List.head
                    in
                    case maybeTodo of
                        Just todo ->
                            let
                                ( tasks, cmd ) =
                                    ConcurrentTask.attempt
                                        { send = send
                                        , pool = model.tasks
                                        , onComplete = GotWrite
                                        }
                                        (toggleTodoTask db todo model.now)
                            in
                            ( { model | tasks = tasks, todos = updatedTodos, eventCount = model.eventCount + 1 }, cmd )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        DeleteTodo id ->
            case model.db of
                Just db ->
                    let
                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotWrite
                                }
                                (deleteTodoTask db id model.now)
                    in
                    ( { model
                        | tasks = tasks
                        , todos = List.filter (\t -> t.id /= id) model.todos
                        , eventCount = model.eventCount + 1
                      }
                    , cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        DeleteCompleted ->
            case model.db of
                Just db ->
                    let
                        completedKeys =
                            model.todos
                                |> List.filter .done
                                |> List.map (\t -> Idb.IntKey t.id)

                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotWrite
                                }
                                (deleteCompletedTask db completedKeys model.now)
                    in
                    ( { model
                        | tasks = tasks
                        , todos = List.filter (\t -> not t.done) model.todos
                        , eventCount = model.eventCount + 1
                      }
                    , cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        ToggleTheme ->
            case model.db of
                Just db ->
                    let
                        newTheme =
                            if model.theme == "light" then
                                "dark"

                            else
                                "light"

                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotWrite
                                }
                                (toggleThemeTask db newTheme model.now)
                    in
                    ( { model | tasks = tasks, theme = newTheme, eventCount = model.eventCount + 1 }, cmd )

                Nothing ->
                    ( model, Cmd.none )

        AddSampleData ->
            case model.db of
                Just db ->
                    let
                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotLoad
                                }
                                (addSampleDataTask db model.now)
                    in
                    ( { model | tasks = tasks }, cmd )

                Nothing ->
                    ( model, Cmd.none )

        ClearTodos ->
            case model.db of
                Just db ->
                    let
                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotWrite
                                }
                                (clearTodosTask db model.now)
                    in
                    ( { model | tasks = tasks, todos = [], nextId = 1, eventCount = model.eventCount + 1 }, cmd )

                Nothing ->
                    ( model, Cmd.none )

        ResetDatabase ->
            case model.db of
                Just db ->
                    let
                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotReset
                                }
                                (resetDatabaseTask db)
                    in
                    ( { model | tasks = tasks }, cmd )

                Nothing ->
                    ( model, Cmd.none )

        SetEventFilter filter ->
            ( { model | eventFilter = filter }, Cmd.none )
                |> andRefreshEvents

        RefreshEvents ->
            ( model, Cmd.none )
                |> andRefreshEvents

        GotLoad response ->
            case response of
                ConcurrentTask.Success data ->
                    let
                        maxId =
                            List.map .id data.todos
                                |> List.maximum
                                |> Maybe.withDefault 0
                    in
                    ( { model
                        | db = Just data.db
                        , todos = data.todos
                        , nextId = maxId + 1
                        , theme = data.theme
                        , eventCount = data.eventCount
                        , todoKeys = data.todoKeys
                        , status = Ready
                      }
                    , Cmd.none
                    )

                ConcurrentTask.Error err ->
                    ( { model | status = Error (errorToString err) }, Cmd.none )

                ConcurrentTask.UnexpectedError err ->
                    ( { model | status = Error (unexpectedErrorToString err) }, Cmd.none )

        GotWrite response ->
            case response of
                ConcurrentTask.Success _ ->
                    ( model, Cmd.none )

                ConcurrentTask.Error err ->
                    ( { model | status = Error (errorToString err) }, Cmd.none )

                ConcurrentTask.UnexpectedError err ->
                    ( { model | status = Error (unexpectedErrorToString err) }, Cmd.none )

        GotReset response ->
            case response of
                ConcurrentTask.Success _ ->
                    -- Database deleted — re-open and reload
                    let
                        ( tasks, cmd ) =
                            ConcurrentTask.attempt
                                { send = send
                                , pool = model.tasks
                                , onComplete = GotLoad
                                }
                                loadApp
                    in
                    ( { model
                        | tasks = tasks
                        , db = Nothing
                        , todos = []
                        , nextId = 1
                        , theme = "light"
                        , eventCount = 0
                        , todoKeys = []
                        , events = []
                        , eventFilter = AllEvents
                        , status = Loading
                      }
                    , cmd
                    )

                ConcurrentTask.Error err ->
                    ( { model | status = Error (errorToString err) }, Cmd.none )

                ConcurrentTask.UnexpectedError err ->
                    ( { model | status = Error (unexpectedErrorToString err) }, Cmd.none )

        GotEvents response ->
            case response of
                ConcurrentTask.Success events ->
                    ( { model | events = events }, Cmd.none )

                ConcurrentTask.Error err ->
                    ( { model | status = Error (errorToString err) }, Cmd.none )

                ConcurrentTask.UnexpectedError err ->
                    ( { model | status = Error (unexpectedErrorToString err) }, Cmd.none )

        OnProgress ( tasks, cmd ) ->
            ( { model | tasks = tasks }, cmd )


andRefreshEvents : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
andRefreshEvents ( model, existingCmd ) =
    case model.db of
        Just db ->
            let
                task =
                    case model.eventFilter of
                        AllEvents ->
                            queryAllEventsTask db

                        RecentEvents ->
                            queryRecentEventsTask db model.now

                        ByAction action ->
                            queryEventsByActionTask db action

                ( tasks, cmd ) =
                    ConcurrentTask.attempt
                        { send = send
                        , pool = model.tasks
                        , onComplete = GotEvents
                        }
                        task
            in
            ( { model | tasks = tasks }, Cmd.batch [ existingCmd, cmd ] )

        Nothing ->
            ( model, existingCmd )


errorToString : Idb.Error -> String
errorToString err =
    case err of
        Idb.AlreadyExists ->
            "Record already exists"

        Idb.TransactionError msg_ ->
            "Transaction error: " ++ msg_

        Idb.QuotaExceeded ->
            "Storage quota exceeded"

        Idb.DatabaseError msg_ ->
            "Database error: " ++ msg_


unexpectedErrorToString : ConcurrentTask.UnexpectedError -> String
unexpectedErrorToString err =
    case err of
        ConcurrentTask.MissingFunction name ->
            "Missing JS function: " ++ name

        ConcurrentTask.ResponseDecoderFailure { function } ->
            "Response decoder failed for: " ++ function

        ConcurrentTask.ErrorsDecoderFailure { function } ->
            "Error decoder failed for: " ++ function

        ConcurrentTask.UnhandledJsException { function, message } ->
            function ++ " threw: " ++ message

        ConcurrentTask.InternalError message ->
            "Internal error: " ++ message



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "font-family" "sans-serif"
        , style "max-width" "520px"
        , style "margin" "40px auto"
        , style "padding" "20px"
        , style "border-radius" "8px"
        , style "background-color"
            (if model.theme == "dark" then
                "#1a1a2e"

             else
                "#fff"
            )
        , style "color"
            (if model.theme == "dark" then
                "#e0e0e0"

             else
                "#333"
            )
        ]
        [ h1 [ style "margin-top" "0" ] [ text "Todo List" ]
        , p [] [ text "Persisted in IndexedDB. Exercises every elm-indexeddb API function." ]
        , case model.status of
            Loading ->
                p [ style "color" "#888" ] [ text "Opening database..." ]

            Error message ->
                p [ style "color" "red" ] [ text ("Error: " ++ message) ]

            Ready ->
                div []
                    [ viewStats model
                    , viewAddForm model
                    , viewTodos model.todos
                    , viewFooter model.todos
                    , viewActions
                    , viewActivityLog model
                    ]
        ]


viewStats : Model -> Html Msg
viewStats model =
    div
        [ style "display" "flex"
        , style "flex-wrap" "wrap"
        , style "gap" "12px"
        , style "margin-bottom" "16px"
        , style "padding" "10px"
        , style "background"
            (if model.theme == "dark" then
                "#16213e"

             else
                "#f5f5f5"
            )
        , style "border-radius" "4px"
        , style "font-size" "13px"
        ]
        [ span [] [ text ("Theme: " ++ model.theme) ]
        , span [] [ text ("Events: " ++ String.fromInt model.eventCount) ]
        , span []
            [ text
                ("Todo keys: ["
                    ++ (model.todoKeys |> List.map keyToString |> String.join ", ")
                    ++ "]"
                )
            ]
        ]


viewAddForm : Model -> Html Msg
viewAddForm model =
    Html.form
        [ onSubmit AddTodo
        , style "display" "flex"
        , style "gap" "8px"
        , style "margin-bottom" "16px"
        ]
        [ Html.input
            [ type_ "text"
            , placeholder "What needs to be done?"
            , value model.input
            , onInput UpdateInput
            , style "flex" "1"
            , style "padding" "8px"
            , style "background"
                (if model.theme == "dark" then
                    "#16213e"

                 else
                    "#fff"
                )
            , style "color" "inherit"
            , style "border" "1px solid #888"
            , style "border-radius" "4px"
            ]
            []
        , button [ type_ "submit", style "padding" "8px 16px" ] [ text "Add" ]
        ]


viewTodos : List Todo -> Html Msg
viewTodos todos =
    if List.isEmpty todos then
        p [ style "color" "#888" ] [ text "No todos yet. Add one above!" ]

    else
        ul [ style "list-style" "none", style "padding" "0", style "margin" "0" ]
            (List.map viewTodo todos)


viewTodo : Todo -> Html Msg
viewTodo todo =
    li
        [ style "display" "flex"
        , style "align-items" "center"
        , style "gap" "8px"
        , style "padding" "8px 0"
        , style "border-bottom" "1px solid #555"
        ]
        [ Html.input
            [ type_ "checkbox"
            , checked todo.done
            , onClick (ToggleTodo todo.id)
            , style "cursor" "pointer"
            ]
            []
        , span
            [ style "flex" "1"
            , style "text-decoration"
                (if todo.done then
                    "line-through"

                 else
                    "none"
                )
            , style "opacity"
                (if todo.done then
                    "0.5"

                 else
                    "1"
                )
            ]
            [ text todo.text ]
        , button
            [ onClick (DeleteTodo todo.id)
            , style "padding" "2px 8px"
            , style "color" "#c00"
            , style "cursor" "pointer"
            , style "border" "none"
            , style "background" "none"
            , style "font-size" "14px"
            ]
            [ text "x" ]
        ]


viewFooter : List Todo -> Html Msg
viewFooter todos =
    if List.isEmpty todos then
        text ""

    else
        let
            remaining =
                List.filter (\t -> not t.done) todos |> List.length

            completed =
                List.filter .done todos |> List.length
        in
        div
            [ style "display" "flex"
            , style "justify-content" "space-between"
            , style "align-items" "center"
            , style "margin-top" "12px"
            , style "font-size" "14px"
            , style "color" "#888"
            ]
            [ span []
                [ text
                    (String.fromInt remaining
                        ++ " of "
                        ++ String.fromInt (List.length todos)
                        ++ " remaining"
                    )
                ]
            , if completed > 0 then
                button
                    [ onClick DeleteCompleted
                    , style "padding" "4px 10px"
                    , style "font-size" "13px"
                    , style "cursor" "pointer"
                    ]
                    [ text ("Delete completed (" ++ String.fromInt completed ++ ")") ]

              else
                text ""
            ]


viewActions : Html Msg
viewActions =
    div
        [ style "display" "flex"
        , style "flex-wrap" "wrap"
        , style "gap" "8px"
        , style "margin-top" "20px"
        , style "padding-top" "16px"
        , style "border-top" "1px solid #555"
        ]
        [ button [ onClick ToggleTheme, style "padding" "6px 12px", style "cursor" "pointer" ]
            [ text "Toggle theme" ]
        , button [ onClick AddSampleData, style "padding" "6px 12px", style "cursor" "pointer" ]
            [ text "Add sample data" ]
        , button [ onClick ClearTodos, style "padding" "6px 12px", style "cursor" "pointer" ]
            [ text "Clear todos" ]
        , button
            [ onClick ResetDatabase
            , style "padding" "6px 12px"
            , style "cursor" "pointer"
            , style "color" "#c00"
            ]
            [ text "Reset database" ]
        ]


viewActivityLog : Model -> Html Msg
viewActivityLog model =
    div
        [ style "margin-top" "24px"
        , style "padding-top" "16px"
        , style "border-top" "1px solid #555"
        ]
        [ h2 [ style "margin-top" "0", style "font-size" "18px" ] [ text "Activity Log" ]
        , p [ style "font-size" "13px", style "color" "#888" ]
            [ text "Query events using secondary indexes and key ranges." ]
        , viewEventFilters model.eventFilter
        , if List.isEmpty model.events then
            p [ style "color" "#888", style "font-size" "13px" ]
                [ text "No events to display. Select a filter to query." ]

          else
            ul [ style "list-style" "none", style "padding" "0", style "margin" "8px 0 0 0" ]
                (List.map viewEvent model.events)
        ]


viewEventFilters : EventFilter -> Html Msg
viewEventFilters current =
    div
        [ style "display" "flex"
        , style "flex-wrap" "wrap"
        , style "gap" "6px"
        , style "margin-bottom" "12px"
        ]
        [ filterButton "All events" AllEvents current
        , filterButton "Last 5 min" RecentEvents current
        , filterButton "add_todo" (ByAction "add_todo") current
        , filterButton "delete_todo" (ByAction "delete_todo") current
        , filterButton "toggle_todo" (ByAction "toggle_todo") current
        , filterButton "toggle_theme" (ByAction "toggle_theme") current
        ]


filterButton : String -> EventFilter -> EventFilter -> Html Msg
filterButton label filter current =
    button
        [ onClick (SetEventFilter filter)
        , style "padding" "4px 10px"
        , style "font-size" "12px"
        , style "cursor" "pointer"
        , style "border"
            (if filter == current then
                "2px solid #4a9eff"

             else
                "1px solid #888"
            )
        , style "border-radius" "12px"
        , style "background"
            (if filter == current then
                "#4a9eff22"

             else
                "transparent"
            )
        ]
        [ text label ]


viewEvent : Event -> Html msg
viewEvent event =
    li
        [ style "padding" "4px 0"
        , style "font-size" "13px"
        , style "border-bottom" "1px solid #333"
        , style "display" "flex"
        , style "gap" "12px"
        ]
        [ span [ style "color" "#888", style "min-width" "140px" ]
            [ text (formatPosix event.timestamp) ]
        , span [ style "font-family" "monospace" ]
            [ text event.action ]
        ]


formatPosix : Time.Posix -> String
formatPosix time =
    let
        ms =
            Time.posixToMillis time

        -- Simple UTC formatting: show as milliseconds timestamp
        -- A real app would use elm/time zones for proper formatting
        seconds =
            ms // 1000

        minutes =
            modBy 60 (seconds // 60)

        hours =
            modBy 24 (seconds // 3600)
    in
    String.padLeft 2 '0' (String.fromInt hours)
        ++ ":"
        ++ String.padLeft 2 '0' (String.fromInt minutes)
        ++ ":"
        ++ String.padLeft 2 '0' (String.fromInt (modBy 60 seconds))
        ++ " UTC"



-- HELPERS


keyToString : Idb.Key -> String
keyToString key =
    case key of
        Idb.StringKey s ->
            "\"" ++ s ++ "\""

        Idb.IntKey i ->
            String.fromInt i

        Idb.FloatKey f ->
            String.fromFloat f

        Idb.PosixKey time ->
            String.fromInt (Time.posixToMillis time)

        Idb.CompoundKey keys ->
            "[" ++ String.join ", " (List.map keyToString keys) ++ "]"
