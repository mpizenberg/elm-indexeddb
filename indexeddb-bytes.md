# Design: elm-indexeddb-bytes

This document holds a potential design for an additional package enabling
Bytes storage in IndexedDB.

------------------------------------------

A standalone package for binary data storage in IndexedDB from Elm, using the
XHR bytes bridge. Fully independent from `elm-indexeddb` — no shared Elm code,
no shared types. Both packages have the same API shape and feel, but manage
separate databases.

## 1. Problem

Elm has no built-in way to store binary data (Bytes) in IndexedDB. The existing
`elm-indexeddb` package routes everything through `elm-concurrent-task`, which
serializes data as JSON through ports. IndexedDB natively supports `ArrayBuffer`
via structured cloning, but JSON ports can't carry binary data.

## 2. Approach

Use `elm-xhr-bytes-bridge` to transfer data between Elm and JS, bypassing ports
entirely. ALL operations — including `open`, `count`, `listKeys` — go through
the XHR bridge, making the package fully independent from `elm-concurrent-task`.

The package defines its own types (`Db`, `BlobStore`, `Key`, `Error`, `Schema`)
that mirror `elm-indexeddb`'s API shape but are completely separate. All
operations return `Cmd msg`.

## 3. Architecture

```
                    Elm Application
                   /               \
          elm-indexeddb          elm-indexeddb-bytes
        (ConcurrentTask)          (XHR bridge)
         JSON via ports         binary via Http.request
               |                        |
       elm-concurrent-task       xhr-bytes-bridge
           JS runtime             monkeypatch
               |                        |
         databases Map A          databases Map B
               |                        |
         IndexedDB (db: "myapp")  IndexedDB (db: "myblobs")
```

Two fully independent packages. Each maintains its own JS `databases` Map and
opens its own IndexedDB databases. Users should use **different database names**
in each package to avoid schema conflicts.

## 4. Changes to elm-indexeddb

**Elm: none.** The base package is unchanged.

**JS: one optional improvement.** Export the utility functions `decodeKey`,
`encodeKey`, and `normalizeError` so the bytes package can import them instead of
duplicating:

```javascript
// elm-indexeddb/js/src/index.js — add to existing exports
export { createTasks, decodeKey, encodeKey, normalizeError };
```

If we prefer zero changes to elm-indexeddb, the bytes package duplicates these
small utility functions (~40 lines total).

## 5. New Package: elm-indexeddb-bytes

### 5.1 Package Metadata

**elm.json:**

```json
{
  "type": "package",
  "name": "mpizenberg/elm-indexeddb-bytes",
  "summary": "Binary data storage in IndexedDB for Elm via XHR bytes bridge",
  "license": "BSD-3-Clause",
  "version": "1.0.0",
  "exposed-modules": ["IndexedDb.Blob"],
  "elm-version": "0.19.1 <= v < 0.20.0",
  "dependencies": {
    "elm/bytes": "1.0.8 <= v < 2.0.0",
    "elm/core": "1.0.5 <= v < 2.0.0",
    "elm/http": "2.0.0 <= v < 3.0.0",
    "elm/json": "1.1.4 <= v < 2.0.0"
  }
}
```

No dependency on `elm-indexeddb`, `elm-concurrent-task`, or
`elm-xhr-bytes-bridge` on the Elm side. The bridge URL prefix is inlined
(a single string constant).

**package.json:**

```json
{
  "name": "elm-indexeddb-bytes",
  "version": "1.0.0",
  "description": "Binary data storage in IndexedDB for Elm",
  "type": "module",
  "main": "js/src/index.js",
  "exports": "./js/src/index.js",
  "files": ["js/src"],
  "dependencies": {
    "elm-xhr-bytes-bridge": "^1.0.0"
  }
}
```

No JS dependency on `elm-indexeddb` either (utility functions are either imported
or duplicated).

### 5.2 Elm Module: IndexedDb.Blob

#### Own Types

The module defines its own types, mirroring `elm-indexeddb`'s shapes:

```elm
module IndexedDb.Blob exposing
    ( Schema, schema, withStore
    , BlobStore, defineStore, withAutoIncrement
    , ExplicitKey, GeneratedKey
    , Db, open, deleteDatabase
    , Key(..)
    , getBlob
    , putBlob, addBlob
    , insertBlob, replaceBlob
    , deleteBlob, deleteMany, clearStore
    , countStore, listKeys
    , Error(..)
    )
```

Types:

```elm
-- Phantom types
type ExplicitKey = ExplicitKey
type GeneratedKey = GeneratedKey

-- No InlineKey: keyPath extraction from raw bytes is meaningless

type BlobStore k
    = BlobStore { name : String, autoIncrement : Bool }

type Schema
    = Schema { name : String, version : Int, stores : List StoreConfig }

type alias StoreConfig =
    { name : String, autoIncrement : Bool }

type Db
    = Db String

type Key
    = StringKey String
    | IntKey Int
    | FloatKey Float
    | CompoundKey (List Key)

type Error
    = AlreadyExists
    | TransactionError String
    | QuotaExceeded
    | DatabaseError String
```

#### Schema Definition

```elm
schema : String -> Int -> Schema
schema name version =
    Schema { name = name, version = version, stores = [] }

defineStore : String -> BlobStore ExplicitKey
defineStore name =
    BlobStore { name = name, autoIncrement = False }

withAutoIncrement : BlobStore ExplicitKey -> BlobStore GeneratedKey
withAutoIncrement (BlobStore config) =
    BlobStore { config | autoIncrement = True }

withStore : BlobStore k -> Schema -> Schema
withStore (BlobStore config) (Schema s) =
    Schema
        { s
            | stores =
                { name = config.name
                , autoIncrement = config.autoIncrement
                }
                    :: s.stores
        }
```

#### Database Lifecycle

```elm
{-| Open a database with the given schema. Creates or upgrades as needed.
Since this goes through the XHR bridge (not ConcurrentTask), the result
arrives as a Msg.
-}
open : Schema -> (Result Error Db -> msg) -> Cmd msg

{-| Close the connection and delete the database. -}
deleteDatabase : Db -> (Result Error () -> msg) -> Cmd msg
```

`open` sends the schema as a JSON string body via the XHR bridge. The JS handler
runs `indexedDB.open()` with the version and creates/drops stores as needed
(same upgrade logic as `elm-indexeddb`). On success, the `Db` value captures the
database name for subsequent operations.

#### Read Operations

```elm
{-| Get a blob by key. Returns Nothing if the key doesn't exist. -}
getBlob :
    Db
    -> BlobStore k
    -> Key
    -> (Result Error (Maybe Bytes) -> msg)
    -> Cmd msg
```

#### Write Operations — ExplicitKey

```elm
{-| Upsert a blob at the given key. -}
putBlob :
    Db
    -> BlobStore ExplicitKey
    -> Key
    -> Bytes
    -> (Result Error () -> msg)
    -> Cmd msg

{-| Insert a blob at the given key.
Fails with AlreadyExists if the key exists.
-}
addBlob :
    Db
    -> BlobStore ExplicitKey
    -> Key
    -> Bytes
    -> (Result Error () -> msg)
    -> Cmd msg
```

#### Write Operations — GeneratedKey

```elm
{-| Insert a blob with an auto-generated key. Returns the generated key. -}
insertBlob :
    Db
    -> BlobStore GeneratedKey
    -> Bytes
    -> (Result Error Key -> msg)
    -> Cmd msg

{-| Replace a blob at the given key in an auto-increment store. -}
replaceBlob :
    Db
    -> BlobStore GeneratedKey
    -> Key
    -> Bytes
    -> (Result Error () -> msg)
    -> Cmd msg
```

#### Delete Operations

```elm
deleteBlob : Db -> BlobStore k -> Key -> (Result Error () -> msg) -> Cmd msg
deleteMany : Db -> BlobStore k -> List Key -> (Result Error () -> msg) -> Cmd msg
clearStore : Db -> BlobStore k -> (Result Error () -> msg) -> Cmd msg
```

#### Metadata Operations

```elm
countStore : Db -> BlobStore k -> (Result Error Int -> msg) -> Cmd msg
listKeys : Db -> BlobStore k -> (Result Error (List Key) -> msg) -> Cmd msg
```

#### Internal: XHR Bridge Helpers

All operations build `Http.request` calls targeting the XHR bridge. The bridge
URL prefix is inlined:

```elm
xhrPrefix : String
xhrPrefix =
    "https://xbb.localhost/.xhrhook"
```

**Operations with binary body** (putBlob, addBlob, insertBlob, replaceBlob)
use `Http.bytesBody` for the request body and pass metadata in HTTP headers:

```elm
putBlob db store key bytes toMsg =
    Http.request
        { method = "POST"
        , headers =
            [ Http.header "x-idb-db" (getDbName db)
            , Http.header "x-idb-store" (getStoreName store)
            , Http.header "x-idb-key" (Encode.encode 0 (encodeKey key))
            ]
        , url = xhrPrefix ++ "/idb-blob/put-blob"
        , body = Http.bytesBody "application/octet-stream" bytes
        , expect = expectEmpty toMsg
        , timeout = Nothing
        , tracker = Nothing
        }
```

**Operations without binary body** (open, getBlob, deleteBlob, countStore, etc.)
use `Http.stringBody` for JSON metadata or `Http.emptyBody`:

```elm
getBlob db store key toMsg =
    Http.request
        { method = "POST"
        , headers =
            [ Http.header "x-idb-db" (getDbName db)
            , Http.header "x-idb-store" (getStoreName store)
            , Http.header "x-idb-key" (Encode.encode 0 (encodeKey key))
            ]
        , url = xhrPrefix ++ "/idb-blob/get-blob"
        , body = Http.emptyBody
        , expect = expectMaybeBlob toMsg
        , timeout = Nothing
        , tracker = Nothing
        }

open (Schema s) toMsg =
    let
        name = s.name
    in
    Http.request
        { method = "POST"
        , headers = []
        , url = xhrPrefix ++ "/idb-blob/open"
        , body = Http.stringBody "application/json"
            (Encode.encode 0 (encodeSchema s))
        , expect = expectOpen name toMsg
        , timeout = Nothing
        , tracker = Nothing
        }
```

**Response decoders** use `Http.expectBytesResponse` to inspect status codes:

```elm
expectEmpty : (Result Error () -> msg) -> Http.Expect msg
expectEmpty toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ _ ->
                    Ok ()

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


expectMaybeBlob : (Result Error (Maybe Bytes) -> msg) -> Http.Expect msg
expectMaybeBlob toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ { statusCode } body ->
                    if statusCode == 204 then
                        Ok Nothing
                    else
                        Ok (Just body)

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


expectOpen : String -> (Result Error Db -> msg) -> Http.Expect msg
expectOpen name toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ _ ->
                    Ok (Db name)

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


expectKey : (Result Error Key -> msg) -> Http.Expect msg
expectKey toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    decodeUtf8 body
                        |> Maybe.andThen
                            (Decode.decodeString keyDecoder >> Result.toMaybe)
                        |> Result.fromMaybe
                            (DatabaseError "Failed to decode generated key")

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


expectInt : (Result Error Int -> msg) -> Http.Expect msg
expectInt toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    decodeUtf8 body
                        |> Maybe.andThen String.toInt
                        |> Result.fromMaybe
                            (DatabaseError "Failed to decode count")

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


expectKeys : (Result Error (List Key) -> msg) -> Http.Expect msg
expectKeys toMsg =
    Http.expectBytesResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    decodeUtf8 body
                        |> Maybe.andThen
                            (Decode.decodeString (Decode.list keyDecoder)
                                >> Result.toMaybe
                            )
                        |> Result.fromMaybe
                            (DatabaseError "Failed to decode keys")

                Http.BadStatus_ _ body ->
                    Err (decodeErrorFromBody body)

                _ ->
                    Err (DatabaseError "Network error")


decodeErrorFromBody : Bytes -> Error
decodeErrorFromBody body =
    decodeUtf8 body
        |> Maybe.map errorFromString
        |> Maybe.withDefault (DatabaseError "Unknown error")


decodeUtf8 : Bytes -> Maybe String
decodeUtf8 bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
```

The `encodeKey`, `keyDecoder`, and `errorFromString` functions are implemented
in this package (same logic as `elm-indexeddb`, but defined independently):

```elm
encodeKey : Key -> Value
encodeKey key =
    case key of
        StringKey s ->
            Encode.object [ ( "type", Encode.string "string" ), ( "value", Encode.string s ) ]
        IntKey i ->
            Encode.object [ ( "type", Encode.string "int" ), ( "value", Encode.int i ) ]
        FloatKey f ->
            Encode.object [ ( "type", Encode.string "float" ), ( "value", Encode.float f ) ]
        CompoundKey keys ->
            Encode.object [ ( "type", Encode.string "compound" ), ( "value", Encode.list encodeKey keys ) ]


keyDecoder : Decoder Key
-- Same recursive decoder as elm-indexeddb


errorFromString : String -> Error
errorFromString err =
    if err == "ALREADY_EXISTS" then AlreadyExists
    else if err == "QUOTA_EXCEEDED" then QuotaExceeded
    else
        case splitOnce ":" err of
            Just ( "TRANSACTION_ERROR", msg ) -> TransactionError msg
            Just ( "DATABASE_ERROR", msg ) -> DatabaseError msg
            _ -> DatabaseError err
```

### 5.3 JS Module

`js/src/index.js` — a single `install()` function:

```javascript
import * as bridge from "elm-xhr-bytes-bridge/js/xhr-bytes-bridge.js";

export function install() {
  bridge.install();
  const databases = new Map();
  registerHandlers(databases);
}
```

The user calls `install()` once at startup. It installs the XHR bridge
monkeypatch and registers all route handlers.

#### Database Guard

A global registry prevents accidentally opening the same database from both
`elm-indexeddb` and `elm-indexeddb-bytes`:

```javascript
const IDB_GUARD = "__elm_idb_open_databases";

function guardOpen(dbName) {
  if (!window[IDB_GUARD]) window[IDB_GUARD] = new Set();
  if (window[IDB_GUARD].has(dbName)) {
    return (
      "DATABASE_ERROR:Database '" +
      dbName +
      "' is already open. Use a different database name for blob stores."
    );
  }
  window[IDB_GUARD].add(dbName);
  return null;
}

function guardClose(dbName) {
  if (window[IDB_GUARD]) window[IDB_GUARD].delete(dbName);
}
```

The guard is one-sided (only the bytes package checks it) unless we also add it
to `elm-indexeddb`. If the base package also checks the guard, both packages
would prevent collisions. This is a 3-line addition to `elm-indexeddb`'s
`handleOpen` if desired.

#### Utility Functions

Key encoding/decoding and error normalization — same logic as `elm-indexeddb`.
Either imported from `elm-indexeddb` (if it exports them) or duplicated:

```javascript
function decodeKey(encoded) {
  switch (encoded.type) {
    case "string":
      return encoded.value;
    case "int":
      return encoded.value;
    case "float":
      return encoded.value;
    case "compound":
      return encoded.value.map(decodeKey);
    default:
      throw new Error("Unknown key type: " + encoded.type);
  }
}

function encodeKey(native) {
  if (typeof native === "string") return { type: "string", value: native };
  if (typeof native === "number") {
    return Number.isInteger(native)
      ? { type: "int", value: native }
      : { type: "float", value: native };
  }
  if (Array.isArray(native))
    return { type: "compound", value: native.map(encodeKey) };
  throw new Error("Unsupported key type: " + typeof native);
}

function normalizeError(error) {
  const msg = error?.message || String(error);
  if (error?.name === "ConstraintError") return "ALREADY_EXISTS";
  if (error?.name === "QuotaExceededError") return "QUOTA_EXCEEDED";
  if (
    error?.name === "TransactionInactiveError" ||
    error?.name === "AbortError"
  )
    return "TRANSACTION_ERROR:" + msg;
  return "DATABASE_ERROR:" + msg;
}

function mapErrorStatus(error) {
  if (error?.name === "ConstraintError") return 409;
  if (error?.name === "QuotaExceededError") return 507;
  return 500;
}

const textEncoder = new TextEncoder();

function resolveUtf8(resolve, status, str) {
  resolve(status, textEncoder.encode(str).buffer);
}

function parseMeta(req) {
  return {
    dbName: req.headers["x-idb-db"],
    storeName: req.headers["x-idb-store"],
    key: req.headers["x-idb-key"]
      ? JSON.parse(req.headers["x-idb-key"])
      : undefined,
  };
}
```

#### Route Handlers

All routes are prefixed with `idb-blob/` to avoid collisions if both packages
somehow use the XHR bridge in the future.

```javascript
function registerHandlers(databases) {
  // --- open ---
  bridge.handle("idb-blob/open", (req, resolve) => {
    // req.body is a JSON string (sent via Http.stringBody)
    const { name, version, stores } = JSON.parse(req.body);

    const guardError = guardOpen(name);
    if (guardError) return resolveUtf8(resolve, 500, guardError);

    let schemaError = null;
    const request = indexedDB.open(name, version);

    request.onupgradeneeded = (event) => {
      const db = event.target.result;
      const tx = event.target.transaction;
      const schemaStoreNames = stores.map((s) => s.name);

      // Delete stores not in schema
      for (const existing of Array.from(db.objectStoreNames)) {
        if (!schemaStoreNames.includes(existing)) {
          db.deleteObjectStore(existing);
        }
      }

      // Create stores in schema
      for (const storeDef of stores) {
        if (!db.objectStoreNames.contains(storeDef.name)) {
          const options = {};
          if (storeDef.autoIncrement) options.autoIncrement = true;
          db.createObjectStore(storeDef.name, options);
        }
      }
    };

    request.onsuccess = (event) => {
      databases.set(name, event.target.result);
      resolve(200, new ArrayBuffer(0));
    };

    request.onerror = (event) => {
      guardClose(name);
      if (schemaError) {
        resolveUtf8(resolve, 500, schemaError);
      } else {
        resolveUtf8(resolve, 500, normalizeError(event.target.error));
      }
    };
  });

  // --- deleteDatabase ---
  bridge.handle("idb-blob/delete-database", (req, resolve) => {
    const dbName = req.headers["x-idb-db"];
    const existing = databases.get(dbName);
    if (existing) {
      existing.close();
      databases.delete(dbName);
    }
    guardClose(dbName);

    const request = indexedDB.deleteDatabase(dbName);
    request.onsuccess = () => resolve(200, new ArrayBuffer(0));
    request.onerror = () =>
      resolveUtf8(resolve, 500, normalizeError(request.error));
  });

  // --- get-blob ---
  bridge.handle("idb-blob/get-blob", (req, resolve) => {
    const { dbName, storeName, key } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);
    const request = store.get(decodeKey(key));

    request.onsuccess = () => {
      if (request.result === undefined) {
        resolve(204, new ArrayBuffer(0));
      } else if (request.result instanceof ArrayBuffer) {
        resolve(200, request.result);
      } else {
        resolveUtf8(resolve, 500, "DATABASE_ERROR:Value is not an ArrayBuffer");
      }
    };
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });

  // --- put-blob ---
  bridge.handle("idb-blob/put-blob", (req, resolve) => {
    const { dbName, storeName, key } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    store.put(req.body.buffer, decodeKey(key));

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () =>
      resolveUtf8(resolve, mapErrorStatus(tx.error), normalizeError(tx.error));
  });

  // --- add-blob ---
  bridge.handle("idb-blob/add-blob", (req, resolve) => {
    const { dbName, storeName, key } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    store.add(req.body.buffer, decodeKey(key));

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () =>
      resolveUtf8(resolve, mapErrorStatus(tx.error), normalizeError(tx.error));
  });

  // --- insert-blob (auto-increment, returns generated key) ---
  bridge.handle("idb-blob/insert-blob", (req, resolve) => {
    const { dbName, storeName } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    const request = store.put(req.body.buffer);

    request.onsuccess = () => {
      const keyJson = JSON.stringify(encodeKey(request.result));
      resolveUtf8(resolve, 200, keyJson);
    };
    tx.onerror = () =>
      resolveUtf8(resolve, mapErrorStatus(tx.error), normalizeError(tx.error));
  });

  // --- replace-blob ---
  bridge.handle("idb-blob/replace-blob", (req, resolve) => {
    const { dbName, storeName, key } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    store.put(req.body.buffer, decodeKey(key));

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () =>
      resolveUtf8(resolve, mapErrorStatus(tx.error), normalizeError(tx.error));
  });

  // --- delete-blob ---
  bridge.handle("idb-blob/delete-blob", (req, resolve) => {
    const { dbName, storeName, key } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    store.delete(decodeKey(key));

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });

  // --- delete-many ---
  bridge.handle("idb-blob/delete-many", (req, resolve) => {
    const { dbName, storeName } = parseMeta(req);
    // Keys are sent as JSON string body
    const keys = JSON.parse(req.body);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    for (const key of keys) {
      store.delete(decodeKey(key));
    }

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });

  // --- clear-store ---
  bridge.handle("idb-blob/clear-store", (req, resolve) => {
    const { dbName, storeName } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    store.clear();

    tx.oncomplete = () => resolve(200, new ArrayBuffer(0));
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });

  // --- count-store ---
  bridge.handle("idb-blob/count-store", (req, resolve) => {
    const { dbName, storeName } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);
    const request = store.count();

    request.onsuccess = () => resolveUtf8(resolve, 200, String(request.result));
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });

  // --- list-keys ---
  bridge.handle("idb-blob/list-keys", (req, resolve) => {
    const { dbName, storeName } = parseMeta(req);
    const db = databases.get(dbName);
    if (!db) return resolveUtf8(resolve, 500, "DATABASE_ERROR:Not open");

    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);
    const request = store.getAllKeys();

    request.onsuccess = () => {
      const keys = request.result.map(encodeKey);
      resolveUtf8(resolve, 200, JSON.stringify(keys));
    };
    tx.onerror = () => resolveUtf8(resolve, 500, normalizeError(tx.error));
  });
}
```

## 6. Data Flow

### open (schema creation)

```
1. Elm: open appSchema DbOpened
2. Http.request with stringBody containing schema JSON
3. XHR bridge dispatches to "idb-blob/open" handler
4. JS: guardOpen(name) → indexedDB.open(name, version)
5. onupgradeneeded: create/drop object stores
6. onsuccess: databases.set(name, db); resolve(200, empty)
7. Elm: DbOpened (Ok (Db "myblobs"))
```

### putBlob (Elm → IndexedDB)

```
1. Elm: putBlob db store key bytes GotResult
2. Http.request with bytesBody + metadata headers
3. XHR bridge dispatches to "idb-blob/put-blob" handler
4. JS: store.put(arrayBuffer, nativeKey)
5. tx.oncomplete: resolve(200, empty)
6. Elm: GotResult (Ok ())
```

### getBlob (IndexedDB → Elm)

```
1. Elm: getBlob db store key GotBlob
2. Http.request with emptyBody + metadata headers
3. XHR bridge dispatches to "idb-blob/get-blob" handler
4. JS: store.get(nativeKey)
5a. Found:     resolve(200, arrayBuffer)
5b. Not found: resolve(204, empty)
6a. Elm: GotBlob (Ok (Just bytes))
6b. Elm: GotBlob (Ok Nothing)
```

### insertBlob (auto-increment key return)

```
1. Elm: insertBlob db store bytes GotKey
2. Http.request with bytesBody (no key header)
3. XHR bridge dispatches to "idb-blob/insert-blob" handler
4. JS: store.put(arrayBuffer) → auto-increment generates key
5. request.onsuccess: resolve(200, utf8(JSON.stringify(encodeKey(key))))
6. Elm decodes: Bytes → UTF-8 String → JSON → Key
7. GotKey (Ok (IntKey 42))
```

## 7. Error Handling

Errors are encoded as UTF-8 strings in the response body:

| Status | Meaning              | Body content                                    |
| ------ | -------------------- | ----------------------------------------------- |
| 200    | Success              | Result data (bytes or UTF-8)                    |
| 204    | Not found (getBlob)  | Empty                                           |
| 409    | Already exists       | `ALREADY_EXISTS`                                |
| 500    | Database/transaction | `DATABASE_ERROR:...` or `TRANSACTION_ERROR:...` |
| 507    | Quota exceeded       | `QUOTA_EXCEEDED`                                |

On the Elm side, `decodeErrorFromBody` reads the body as UTF-8 and delegates to
`errorFromString`, producing the same `Error` shape as `elm-indexeddb`.

## 8. User Setup

### elm-indexeddb-bytes only (standalone)

```javascript
import { install as installBlobStore } from "elm-indexeddb-bytes";

const app = Elm.Main.init({ node: document.getElementById("app") });
installBlobStore();
```

No ports, no ConcurrentTask. Just one `install()` call.

### Both packages together

```javascript
import * as ConcurrentTask from "@andrewmacmurray/elm-concurrent-task";
import { createTasks } from "elm-indexeddb";
import { install as installBlobStore } from "elm-indexeddb-bytes";

const app = Elm.Main.init({ node: document.getElementById("app") });

// For JSON stores (elm-indexeddb)
ConcurrentTask.register({
  tasks: createTasks(),
  ports: { send: app.ports.send, receive: app.ports.receive },
});

// For blob stores (elm-indexeddb-bytes)
installBlobStore();
```

### Elm Usage Example (standalone)

```elm
import Bytes exposing (Bytes)
import IndexedDb.Blob as Blob exposing (BlobStore, Db, Key(..))


-- Schema

filesStore : BlobStore Blob.ExplicitKey
filesStore =
    Blob.defineStore "files"

blobSchema : Blob.Schema
blobSchema =
    Blob.schema "myblobs" 1
        |> Blob.withStore filesStore


-- Initialization

type Model
    = Loading
    | Ready Db
    | Failed String

type Msg
    = DbOpened (Result Blob.Error Db)
    | FileSaved (Result Blob.Error ())
    | FileLoaded (Result Blob.Error (Maybe Bytes))

init : ( Model, Cmd Msg )
init =
    ( Loading
    , Blob.open blobSchema DbOpened
    )

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DbOpened (Ok db) ->
            ( Ready db, Cmd.none )

        DbOpened (Err err) ->
            ( Failed "Could not open database", Cmd.none )

        FileSaved (Ok ()) ->
            ( model, Cmd.none )

        FileLoaded (Ok (Just bytes)) ->
            -- use the bytes
            ( model, Cmd.none )

        FileLoaded (Ok Nothing) ->
            -- not found
            ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


-- Operations

saveFile : Db -> String -> Bytes -> Cmd Msg
saveFile db filename bytes =
    Blob.putBlob db filesStore (StringKey filename) bytes FileSaved

loadFile : Db -> String -> Cmd Msg
loadFile db filename =
    Blob.getBlob db filesStore (StringKey filename) FileLoaded
```

### Elm Usage Example (both packages)

```elm
import IndexedDb as Idb
import IndexedDb.Blob as Blob


-- Separate schemas, separate databases

jsonSchema : Idb.Schema
jsonSchema =
    Idb.schema "myapp" 1
        |> Idb.withStore todosStore

blobSchema : Blob.Schema
blobSchema =
    Blob.schema "myapp-files" 1
        |> Blob.withStore filesStore
```

Note: use **different database names** for each package.

## 9. Impact on elm-indexeddb

**Zero changes required.** The base package is completely unmodified.

Optionally, exporting `decodeKey`, `encodeKey`, `normalizeError` from the JS
module avoids ~40 lines of duplication in the bytes package. This is a
non-breaking, non-functional change.

## 10. Limitations and Future Work

**Separate databases.** JSON and blob data live in different IndexedDB databases.
This is inherent to the fully independent design. If an application needs JSON
and blob data in the same database (e.g., for cross-store transactions), this
package doesn't support that.

**All operations are `Cmd msg`.** No `ConcurrentTask` chaining. Operations are
independent request-response cycles, composed through Elm's normal update loop.

**No batch blob operations.** Each write is a separate XHR request and IndexedDB
transaction. Cannot group multiple blob writes into a single atomic transaction.

**No getAllBlobs.** Returning multiple blobs in one response would require a
custom binary framing protocol. Use `listKeys` + individual `getBlob` calls.

**No InlineKey blob stores.** A keyPath into raw bytes is meaningless.

**XHR monkeypatch always installed.** The patch is idempotent and only intercepts
`xbb.localhost` URLs, so it's harmless.

**Database name collisions.** If both packages open the same database name,
schema version conflicts may occur. The bytes package includes a one-sided guard
(global Set) that detects this and returns a clear error. For full protection,
`elm-indexeddb` could add the same 3-line guard check.

**Code duplication.** Key encoding/decoding, error normalization, and schema
upgrade logic are duplicated between the two JS packages (~80 lines). This is the
tradeoff for full independence. The JS duplication can be reduced if
`elm-indexeddb` exports its utility functions.

## 11. File Structure

```
elm-indexeddb-bytes/
├── elm.json
├── package.json
├── src/
│   └── IndexedDb/
│       └── Blob.elm          # Full standalone module
├── js/
│   └── src/
│       └── index.js          # install() + XHR bridge handlers
└── example/
    ├── src/
    │   └── Main.elm          # Example app
    └── index.html
```

## 12. Summary

| Aspect                   | elm-indexeddb                        | elm-indexeddb-bytes           |
| ------------------------ | ------------------------------------ | ----------------------------- |
| Transport                | ConcurrentTask (JSON ports)          | XHR bytes bridge              |
| Operations return        | `ConcurrentTask Error a`             | `Cmd msg`                     |
| Value type               | `Json.Encode.Value`                  | `Bytes`                       |
| Store key types          | ExplicitKey, InlineKey, GeneratedKey | ExplicitKey, GeneratedKey     |
| Elm deps                 | elm-concurrent-task, elm/json        | elm/http, elm/bytes, elm/json |
| JS deps                  | elm-concurrent-task                  | elm-xhr-bytes-bridge          |
| Ports needed             | Yes (send/receive)                   | No                            |
| Changes to elm-indexeddb | None                                 | None                          |
