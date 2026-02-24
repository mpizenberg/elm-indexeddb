module IndexedDb exposing
    ( Schema, schema, withStore
    , Store, defineStore, withKeyPath, withAutoIncrement
    , Index, defineIndex, uniqueIndex, multiEntryIndex, withIndex
    , ExplicitKey, InlineKey, GeneratedKey
    , Db, open, deleteDatabase
    , Key(..), keyToPosix
    , KeyRange, only, from, above, upTo, below, between
    , get, getAll, getAllKeys, count
    , getAllInRange, getAllKeysInRange, countInRange
    , getByIndex, getKeysByIndex, countByIndex
    , put, add, putMany
    , putAt, addAt, putManyAt
    , insert, replace, insertMany, replaceMany
    , delete, deleteMany, clear, deleteInRange
    , Error(..)
    )

{-| IndexedDB support for Elm via elm-concurrent-task.


# Design Decisions

  - Single database per schema — one `Db` handle, one connection
  - Phantom types enforce key discipline at compile time
  - Each operation runs in its own transaction (no multi-store transactions)
  - Batch variants (`putMany`, etc.) run in a single transaction for atomicity
  - `get` returns `Maybe` for missing keys instead of an error, matching native IndexedDB behavior
  - Relies on `elm-concurrent-task` for all async JS interop


# Not Yet Supported

  - Cursors (streaming iteration over large result sets)
  - Multi-store transactions
  - Compound key paths


# Initialization

@docs Schema, schema, withStore
@docs Store, defineStore, withKeyPath, withAutoIncrement
@docs Index, defineIndex, uniqueIndex, multiEntryIndex, withIndex
@docs ExplicitKey, InlineKey, GeneratedKey


# Database

@docs Db, open, deleteDatabase


# Keys

@docs Key, keyToPosix


# Key Ranges

@docs KeyRange, only, from, above, upTo, below, between


# Read Operations

@docs get, getAll, getAllKeys, count
@docs getAllInRange, getAllKeysInRange, countInRange
@docs getByIndex, getKeysByIndex, countByIndex


# Write Operations — InlineKey stores

@docs put, add, putMany


# Write Operations — ExplicitKey stores

@docs putAt, addAt, putManyAt


# Write Operations — GeneratedKey stores

@docs insert, replace, insertMany, replaceMany


# Delete Operations

@docs delete, deleteMany, clear, deleteInRange


# Errors

@docs Error

-}

import ConcurrentTask exposing (ConcurrentTask)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Set
import Time



-- PHANTOM TYPES


{-| Marker type for stores where the key must be provided explicitly.
-}
type ExplicitKey
    = ExplicitKey


{-| Marker type for stores where the key is extracted from the value via keyPath.
-}
type InlineKey
    = InlineKey


{-| Marker type for stores where the key is auto-generated.
-}
type GeneratedKey
    = GeneratedKey



-- STORE


{-| A store definition with a phantom type `k` indicating its key configuration.
-}
type Store k
    = Store
        { name : String
        , keyPath : Maybe String
        , autoIncrement : Bool
        , indexes : List IndexConfig
        }


{-| Define a new store with explicit keys (no keyPath, no autoIncrement).

    rawStore : Store ExplicitKey
    rawStore =
        defineStore "raw"

-}
defineStore : String -> Store ExplicitKey
defineStore name =
    Store { name = name, keyPath = Nothing, autoIncrement = False, indexes = [] }


{-| Set a keyPath on a store, making it an InlineKey store.

    todosStore : Store InlineKey
    todosStore =
        defineStore "todos"
            |> withKeyPath "id"

-}
withKeyPath : String -> Store ExplicitKey -> Store InlineKey
withKeyPath path (Store config) =
    Store { config | keyPath = Just path }


{-| Enable auto-increment on a store, making it a GeneratedKey store.

    cacheStore : Store GeneratedKey
    cacheStore =
        defineStore "cache"
            |> withAutoIncrement

-}
withAutoIncrement : Store ExplicitKey -> Store GeneratedKey
withAutoIncrement (Store config) =
    Store { config | autoIncrement = True }


{-| Add an index to a store. The index is used for secondary key lookups
and range queries on fields other than the primary key.

    eventsStore : Store InlineKey
    eventsStore =
        defineStore "events"
            |> withKeyPath "id"
            |> withIndex (defineIndex "by_timestamp" "timestamp")

-}
withIndex : Index -> Store k -> Store k
withIndex (Index indexConfig) (Store config) =
    Store { config | indexes = indexConfig :: config.indexes }



-- INDEX


{-| An index definition for secondary key lookups on a store.
-}
type Index
    = Index IndexConfig


type alias IndexConfig =
    { name : String
    , keyPath : String
    , unique : Bool
    , multiEntry : Bool
    }


{-| Define a new index with a name and keyPath. By default, the index is
non-unique and single-entry.

    byTimestamp : Index
    byTimestamp =
        defineIndex "by_timestamp" "timestamp"

-}
defineIndex : String -> String -> Index
defineIndex name keyPath =
    Index { name = name, keyPath = keyPath, unique = False, multiEntry = False }


{-| Make an index enforce uniqueness. Adding a record with a duplicate
value for this index's keyPath will fail with `AlreadyExists`.

    byEmail : Index
    byEmail =
        defineIndex "by_email" "email"
            |> uniqueIndex

-}
uniqueIndex : Index -> Index
uniqueIndex (Index config) =
    Index { config | unique = True }


{-| Make an index treat array values as multiple entries. Each element
of the array gets its own entry in the index, all pointing to the same record.

    byTags : Index
    byTags =
        defineIndex "by_tags" "tags"
            |> multiEntryIndex

-}
multiEntryIndex : Index -> Index
multiEntryIndex (Index config) =
    Index { config | multiEntry = True }



-- SCHEMA


{-| A database schema: name, version, and a list of store definitions.
-}
type Schema
    = Schema
        { name : String
        , version : Int
        , stores : List StoreConfig
        }


type alias StoreConfig =
    { name : String
    , keyPath : Maybe String
    , autoIncrement : Bool
    , indexes : List IndexConfig
    }


{-| Start building a schema with a database name and version number.

    mySchema : Schema
    mySchema =
        schema "myapp" 1
            |> withStore todosStore
            |> withStore cacheStore

-}
schema : String -> Int -> Schema
schema name version =
    Schema { name = name, version = version, stores = [] }


{-| Add a store to the schema. The phantom type is erased—stores of any key
configuration can be added to the same schema.
-}
withStore : Store k -> Schema -> Schema
withStore (Store config) (Schema s) =
    Schema { s | stores = config :: s.stores }



-- DATABASE


{-| An opaque handle to an opened database. Must be threaded to all operations.
-}
type Db
    = Db String


{-| Open a database with the given schema. Creates or upgrades the database
as needed (adding new stores, removing stores not in the schema).

    open mySchema

-}
open : Schema -> ConcurrentTask Error Db
open (Schema s) =
    let
        stores : List StoreConfig
        stores =
            List.reverse s.stores

        names : List String
        names =
            List.map .name stores

        duplicates : List String
        duplicates =
            findDuplicates names
    in
    if List.isEmpty duplicates then
        ConcurrentTask.define
            { function = "indexeddb:open"
            , expect = ConcurrentTask.expectWhatever
            , errors = ConcurrentTask.expectErrors errorDecoder
            , args = encodeSchema s.name s.version stores
            }
            |> ConcurrentTask.map (\() -> Db s.name)

    else
        ConcurrentTask.fail
            (DatabaseError
                ("Duplicate store names in schema: "
                    ++ String.join ", " duplicates
                )
            )


{-| Delete a database. Closes the connection first.
-}
deleteDatabase : Db -> ConcurrentTask Error ()
deleteDatabase db =
    ConcurrentTask.define
        { function = "indexeddb:deleteDatabase"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args = Encode.object [ ( "db", Encode.string (getDbName db) ) ]
        }



-- KEY


{-| A key for IndexedDB records. Constructors are exposed directly.

    StringKey "user-1"

    IntKey 42

    PosixKey (Time.millisToPosix 1700000000000)

    CompoundKey [ StringKey "2024", IntKey 1 ]

-}
type Key
    = StringKey String
    | IntKey Int
    | FloatKey Float
    | PosixKey Time.Posix
    | CompoundKey (List Key)


{-| Extract a `Time.Posix` from a key, if it is a `PosixKey`.
-}
keyToPosix : Key -> Maybe Time.Posix
keyToPosix key =
    case key of
        PosixKey time ->
            Just time

        _ ->
            Nothing



-- KEY RANGE


{-| A range of keys for filtering queries at the IndexedDB level.
Use the convenience constructors below to create ranges.
-}
type KeyRange
    = Only Key
    | LowerBound Key Bool
    | UpperBound Key Bool
    | Bound Key Key Bool Bool


{-| Match a single key exactly.
-}
only : Key -> KeyRange
only key =
    Only key


{-| Match all keys greater than or equal to the given key (inclusive).
-}
from : Key -> KeyRange
from key =
    LowerBound key False


{-| Match all keys strictly greater than the given key (exclusive).
-}
above : Key -> KeyRange
above key =
    LowerBound key True


{-| Match all keys less than or equal to the given key (inclusive).
-}
upTo : Key -> KeyRange
upTo key =
    UpperBound key False


{-| Match all keys strictly less than the given key (exclusive).
-}
below : Key -> KeyRange
below key =
    UpperBound key True


{-| Match all keys between two bounds (inclusive on both ends).
-}
between : Key -> Key -> KeyRange
between lower upper =
    Bound lower upper False False



-- ERROR


{-| Errors that can occur during IndexedDB operations.

  - `AlreadyExists` — Attempted to `add` a record with an existing key.
  - `TransactionError` — The transaction failed (e.g. was aborted).
  - `QuotaExceeded` — Storage quota exceeded.
  - `DatabaseError` — Any other database error (schema mismatch, not open, etc).

-}
type Error
    = AlreadyExists
    | TransactionError String
    | QuotaExceeded
    | DatabaseError String



-- READ OPERATIONS


{-| Get a single record by key. Returns `Nothing` if the key doesn't exist.
-}
get : Db -> Store k -> Key -> Decoder a -> ConcurrentTask Error (Maybe a)
get db store key decoder =
    ConcurrentTask.define
        { function = "indexeddb:get"
        , expect = ConcurrentTask.expectJson (Decode.nullable decoder)
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "key", encodeKey key )
                ]
        }


{-| Get all records in a store, with their keys.
Both keys and values are retrieved in a single transaction for consistency.
-}
getAll : Db -> Store k -> Decoder a -> ConcurrentTask Error (List ( Key, a ))
getAll db store decoder =
    ConcurrentTask.define
        { function = "indexeddb:getAll"
        , expect =
            ConcurrentTask.expectJson
                (Decode.list
                    (Decode.map2 Tuple.pair
                        (Decode.field "key" keyDecoder)
                        (Decode.field "value" decoder)
                    )
                )
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                ]
        }


{-| Get all primary keys in a store.
-}
getAllKeys : Db -> Store k -> ConcurrentTask Error (List Key)
getAllKeys db store =
    ConcurrentTask.define
        { function = "indexeddb:getAllKeys"
        , expect = ConcurrentTask.expectJson (Decode.list keyDecoder)
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                ]
        }


{-| Count the number of records in a store.
-}
count : Db -> Store k -> ConcurrentTask Error Int
count db store =
    ConcurrentTask.define
        { function = "indexeddb:count"
        , expect = ConcurrentTask.expectJson Decode.int
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                ]
        }



-- RANGE READ OPERATIONS


{-| Get all records whose primary key falls within a range, with their keys.
-}
getAllInRange : Db -> Store k -> KeyRange -> Decoder a -> ConcurrentTask Error (List ( Key, a ))
getAllInRange db store range decoder =
    ConcurrentTask.define
        { function = "indexeddb:getAll"
        , expect =
            ConcurrentTask.expectJson
                (Decode.list
                    (Decode.map2 Tuple.pair
                        (Decode.field "key" keyDecoder)
                        (Decode.field "value" decoder)
                    )
                )
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "range", encodeKeyRange range )
                ]
        }


{-| Get all primary keys that fall within a range.
-}
getAllKeysInRange : Db -> Store k -> KeyRange -> ConcurrentTask Error (List Key)
getAllKeysInRange db store range =
    ConcurrentTask.define
        { function = "indexeddb:getAllKeys"
        , expect = ConcurrentTask.expectJson (Decode.list keyDecoder)
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "range", encodeKeyRange range )
                ]
        }


{-| Count records whose primary key falls within a range.
-}
countInRange : Db -> Store k -> KeyRange -> ConcurrentTask Error Int
countInRange db store range =
    ConcurrentTask.define
        { function = "indexeddb:count"
        , expect = ConcurrentTask.expectJson Decode.int
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "range", encodeKeyRange range )
                ]
        }



-- INDEX READ OPERATIONS


{-| Get all records matching an index key range, with their primary keys.
The returned keys are primary keys, usable with `get`, `delete`, etc.

    Idb.getByIndex db
        eventsStore
        byTimestamp
        (Idb.between (Idb.PosixKey start) (Idb.PosixKey end))
        eventDecoder

-}
getByIndex : Db -> Store k -> Index -> KeyRange -> Decoder a -> ConcurrentTask Error (List ( Key, a ))
getByIndex db store index range decoder =
    ConcurrentTask.define
        { function = "indexeddb:getAll"
        , expect =
            ConcurrentTask.expectJson
                (Decode.list
                    (Decode.map2 Tuple.pair
                        (Decode.field "key" keyDecoder)
                        (Decode.field "value" decoder)
                    )
                )
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "index", Encode.string (getIndexName index) )
                , ( "range", encodeKeyRange range )
                ]
        }


{-| Get all primary keys for records matching an index key range.
-}
getKeysByIndex : Db -> Store k -> Index -> KeyRange -> ConcurrentTask Error (List Key)
getKeysByIndex db store index range =
    ConcurrentTask.define
        { function = "indexeddb:getAllKeys"
        , expect = ConcurrentTask.expectJson (Decode.list keyDecoder)
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "index", Encode.string (getIndexName index) )
                , ( "range", encodeKeyRange range )
                ]
        }


{-| Count records matching an index key range.
-}
countByIndex : Db -> Store k -> Index -> KeyRange -> ConcurrentTask Error Int
countByIndex db store index range =
    ConcurrentTask.define
        { function = "indexeddb:count"
        , expect = ConcurrentTask.expectJson Decode.int
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "index", Encode.string (getIndexName index) )
                , ( "range", encodeKeyRange range )
                ]
        }



-- WRITE OPERATIONS: InlineKey


{-| Upsert a value into an InlineKey store. The key is extracted from the
value at the store's keyPath. Returns the key.
-}
put : Db -> Store InlineKey -> Value -> ConcurrentTask Error Key
put db store value =
    ConcurrentTask.define
        { function = "indexeddb:put"
        , expect = ConcurrentTask.expectJson keyDecoder
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "value", value )
                ]
        }


{-| Insert a value into an InlineKey store. Fails with `AlreadyExists` if
the key (extracted from the value) already exists. Returns the key.
-}
add : Db -> Store InlineKey -> Value -> ConcurrentTask Error Key
add db store value =
    ConcurrentTask.define
        { function = "indexeddb:add"
        , expect = ConcurrentTask.expectJson keyDecoder
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "value", value )
                ]
        }


{-| Put many values into an InlineKey store in a single transaction.
-}
putMany : Db -> Store InlineKey -> List Value -> ConcurrentTask Error ()
putMany db store values =
    ConcurrentTask.define
        { function = "indexeddb:putMany"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "entries", Encode.list (\v -> Encode.object [ ( "value", v ) ]) values )
                ]
        }



-- WRITE OPERATIONS: ExplicitKey


{-| Upsert a value at the given key in an ExplicitKey store.
-}
putAt : Db -> Store ExplicitKey -> Key -> Value -> ConcurrentTask Error ()
putAt db store key value =
    ConcurrentTask.define
        { function = "indexeddb:put"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "key", encodeKey key )
                , ( "value", value )
                ]
        }


{-| Insert a value at the given key in an ExplicitKey store. Fails with
`AlreadyExists` if the key already exists.
-}
addAt : Db -> Store ExplicitKey -> Key -> Value -> ConcurrentTask Error ()
addAt db store key value =
    ConcurrentTask.define
        { function = "indexeddb:add"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "key", encodeKey key )
                , ( "value", value )
                ]
        }


{-| Put many key-value pairs into an ExplicitKey store in a single transaction.
-}
putManyAt : Db -> Store ExplicitKey -> List ( Key, Value ) -> ConcurrentTask Error ()
putManyAt db store pairs =
    ConcurrentTask.define
        { function = "indexeddb:putMany"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "entries"
                  , Encode.list
                        (\( k, v ) ->
                            Encode.object
                                [ ( "key", encodeKey k )
                                , ( "value", v )
                                ]
                        )
                        pairs
                  )
                ]
        }



-- WRITE OPERATIONS: GeneratedKey


{-| Insert a value into a GeneratedKey store. The key is auto-generated.
Returns the generated key.
-}
insert : Db -> Store GeneratedKey -> Value -> ConcurrentTask Error Key
insert db store value =
    ConcurrentTask.define
        { function = "indexeddb:put"
        , expect = ConcurrentTask.expectJson keyDecoder
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "value", value )
                ]
        }


{-| Replace a value at the given key in a GeneratedKey store.
Use this to update an existing record whose key was returned by `insert`.
-}
replace : Db -> Store GeneratedKey -> Key -> Value -> ConcurrentTask Error ()
replace db store key value =
    ConcurrentTask.define
        { function = "indexeddb:put"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "key", encodeKey key )
                , ( "value", value )
                ]
        }


{-| Insert many values into a GeneratedKey store in a single transaction.
Returns the generated keys in the same order as the input values.
-}
insertMany : Db -> Store GeneratedKey -> List Value -> ConcurrentTask Error (List Key)
insertMany db store values =
    ConcurrentTask.define
        { function = "indexeddb:insertMany"
        , expect = ConcurrentTask.expectJson (Decode.list keyDecoder)
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "values", Encode.list identity values )
                ]
        }


{-| Replace many values in a GeneratedKey store in a single transaction.
Use this to update existing records whose keys were returned by `insert` or `insertMany`.
-}
replaceMany : Db -> Store GeneratedKey -> List ( Key, Value ) -> ConcurrentTask Error ()
replaceMany db store pairs =
    ConcurrentTask.define
        { function = "indexeddb:putMany"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "entries"
                  , Encode.list
                        (\( k, v ) ->
                            Encode.object
                                [ ( "key", encodeKey k )
                                , ( "value", v )
                                ]
                        )
                        pairs
                  )
                ]
        }



-- DELETE OPERATIONS


{-| Delete a record by key.
-}
delete : Db -> Store k -> Key -> ConcurrentTask Error ()
delete db store key =
    ConcurrentTask.define
        { function = "indexeddb:delete"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "key", encodeKey key )
                ]
        }


{-| Delete all records in a store.
-}
clear : Db -> Store k -> ConcurrentTask Error ()
clear db store =
    ConcurrentTask.define
        { function = "indexeddb:clear"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                ]
        }


{-| Delete many records by key in a single transaction.
-}
deleteMany : Db -> Store k -> List Key -> ConcurrentTask Error ()
deleteMany db store keys =
    ConcurrentTask.define
        { function = "indexeddb:deleteMany"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "keys", Encode.list encodeKey keys )
                ]
        }


{-| Delete all records whose primary key falls within a range.
-}
deleteInRange : Db -> Store k -> KeyRange -> ConcurrentTask Error ()
deleteInRange db store range =
    ConcurrentTask.define
        { function = "indexeddb:delete"
        , expect = ConcurrentTask.expectWhatever
        , errors = ConcurrentTask.expectErrors errorDecoder
        , args =
            Encode.object
                [ ( "db", Encode.string (getDbName db) )
                , ( "store", Encode.string (getStoreName store) )
                , ( "range", encodeKeyRange range )
                ]
        }



-- INTERNAL: Encoders / Decoders


getDbName : Db -> String
getDbName (Db name) =
    name


getStoreName : Store k -> String
getStoreName (Store config) =
    config.name


getIndexName : Index -> String
getIndexName (Index config) =
    config.name


encodeKey : Key -> Value
encodeKey key =
    case key of
        StringKey s ->
            Encode.object
                [ ( "type", Encode.string "string" )
                , ( "value", Encode.string s )
                ]

        IntKey i ->
            Encode.object
                [ ( "type", Encode.string "int" )
                , ( "value", Encode.int i )
                ]

        FloatKey f ->
            Encode.object
                [ ( "type", Encode.string "float" )
                , ( "value", Encode.float f )
                ]

        PosixKey time ->
            Encode.object
                [ ( "type", Encode.string "posix" )
                , ( "value", Encode.int (Time.posixToMillis time) )
                ]

        CompoundKey keys ->
            Encode.object
                [ ( "type", Encode.string "compound" )
                , ( "value", Encode.list encodeKey keys )
                ]


keyDecoder : Decoder Key
keyDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\t ->
                case t of
                    "string" ->
                        Decode.map StringKey (Decode.field "value" Decode.string)

                    "int" ->
                        Decode.map IntKey (Decode.field "value" Decode.int)

                    "float" ->
                        Decode.map FloatKey (Decode.field "value" Decode.float)

                    "posix" ->
                        Decode.map (\ms -> PosixKey (Time.millisToPosix ms))
                            (Decode.field "value" Decode.int)

                    "compound" ->
                        Decode.map CompoundKey
                            (Decode.field "value"
                                (Decode.list (Decode.lazy (\_ -> keyDecoder)))
                            )

                    _ ->
                        Decode.fail ("Unknown key type: " ++ t)
            )


encodeSchema : String -> Int -> List StoreConfig -> Value
encodeSchema name version stores =
    Encode.object
        [ ( "name", Encode.string name )
        , ( "version", Encode.int version )
        , ( "stores", Encode.list encodeStoreConfig stores )
        ]


encodeStoreConfig : StoreConfig -> Value
encodeStoreConfig config =
    Encode.object
        [ ( "name", Encode.string config.name )
        , ( "keyPath"
          , case config.keyPath of
                Just p ->
                    Encode.string p

                Nothing ->
                    Encode.null
          )
        , ( "autoIncrement", Encode.bool config.autoIncrement )
        , ( "indexes", Encode.list encodeIndexConfig config.indexes )
        ]


encodeIndexConfig : IndexConfig -> Value
encodeIndexConfig config =
    Encode.object
        [ ( "name", Encode.string config.name )
        , ( "keyPath", Encode.string config.keyPath )
        , ( "unique", Encode.bool config.unique )
        , ( "multiEntry", Encode.bool config.multiEntry )
        ]


encodeKeyRange : KeyRange -> Value
encodeKeyRange range =
    case range of
        Only key ->
            Encode.object
                [ ( "type", Encode.string "only" )
                , ( "key", encodeKey key )
                ]

        LowerBound key isOpen ->
            Encode.object
                [ ( "type", Encode.string "lowerBound" )
                , ( "key", encodeKey key )
                , ( "open", Encode.bool isOpen )
                ]

        UpperBound key isOpen ->
            Encode.object
                [ ( "type", Encode.string "upperBound" )
                , ( "key", encodeKey key )
                , ( "open", Encode.bool isOpen )
                ]

        Bound lower upper lowerOpen upperOpen ->
            Encode.object
                [ ( "type", Encode.string "bound" )
                , ( "lower", encodeKey lower )
                , ( "upper", encodeKey upper )
                , ( "lowerOpen", Encode.bool lowerOpen )
                , ( "upperOpen", Encode.bool upperOpen )
                ]


errorDecoder : Decoder Error
errorDecoder =
    Decode.string
        |> Decode.andThen
            (\err ->
                if err == "ALREADY_EXISTS" then
                    Decode.succeed AlreadyExists

                else if err == "QUOTA_EXCEEDED" then
                    Decode.succeed QuotaExceeded

                else
                    case splitOnce ":" err of
                        Just ( "TRANSACTION_ERROR", msg ) ->
                            Decode.succeed (TransactionError msg)

                        Just ( "DATABASE_ERROR", msg ) ->
                            Decode.succeed (DatabaseError msg)

                        _ ->
                            Decode.fail ("Unknown IndexedDB error: " ++ err)
            )


findDuplicates : List String -> List String
findDuplicates names =
    names
        |> List.foldl
            (\name ( seen, dupes ) ->
                if Set.member name seen then
                    ( seen, Set.insert name dupes )

                else
                    ( Set.insert name seen, dupes )
            )
            ( Set.empty, Set.empty )
        |> Tuple.second
        |> Set.toList


splitOnce : String -> String -> Maybe ( String, String )
splitOnce sep str =
    case String.indexes sep str of
        i :: _ ->
            Just
                ( String.left i str
                , String.dropLeft (i + String.length sep) str
                )

        [] ->
            Nothing
