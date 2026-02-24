# Todo app example

A todo list that persists in IndexedDB, demonstrating every `elm-indexeddb` feature: three store types, secondary indexes, key range queries, time-based filtering, and batch operations.

## Running

```sh
npm install
elm make src/Main.elm --output=static/elm.js
npx esbuild src/index.js --bundle --outfile=static/main.js
cd static
python -m http.server 8000
```

Open `http://localhost:8000`. Add todos, reload the page -- they persist. Toggle the theme -- it persists too. Check the Activity Log section to see index and range queries in action.

## What the app demonstrates

### Three store types

```elm
todosStore : Idb.Store Idb.InlineKey          -- key from value's "id" field
settingsStore : Idb.Store Idb.ExplicitKey     -- key provided on each write
eventsStore : Idb.Store Idb.GeneratedKey      -- key auto-generated
```

The compiler enforces correct operations per store type. You cannot call `putAt` on an `InlineKey` store, or `put` on a `GeneratedKey` store.

### Secondary indexes

The events store has two indexes for efficient queries:

```elm
byTimestamp : Idb.Index
byTimestamp = Idb.defineIndex "by_timestamp" "timestamp"

byAction : Idb.Index
byAction = Idb.defineIndex "by_action" "action"

eventsStore =
    Idb.defineStore "events"
        |> Idb.withAutoIncrement
        |> Idb.withIndex byTimestamp
        |> Idb.withIndex byAction
```

### Key range queries

The Activity Log section queries events using ranges and indexes:

- **Time range**: "Last 5 min" uses `getByIndex` with `between (PosixKey fiveMinAgo) (PosixKey now)` on the timestamp index
- **Action filter**: buttons like "add_todo" use `getByIndex` with `only (StringKey "add_todo")` on the action index
- **All events**: uses `getAll` without any range

### Event logging with timestamps

Every user action (add, toggle, delete, theme change) inserts an event with the current `Time.Posix`, which the timestamp index stores as a native `Date` for correct ordering.

### Patterns worth noting

- **`addAt` with error recovery**: `initDefaults` seeds a default theme, then `onError` silently ignores `AlreadyExists` on subsequent loads.
- **Parallel loading**: `loadData` uses `ConcurrentTask.map3` to run `getAll`, `get`, and `count` concurrently.
- **Parallel writes**: `addTodoTask` uses `ConcurrentTask.map2` to insert the todo and log the event concurrently.
- **Batch + reload**: "Add sample data" uses `ConcurrentTask.batch` for parallel batch writes, then `andThenDo` to reload.
- **Reset cycle**: "Reset database" calls `deleteDatabase`, then re-runs `open` -> seed defaults -> load data.

## API coverage

| Function                           | Where used                                          |
| ---------------------------------- | --------------------------------------------------- |
| `schema`, `withStore`              | `appSchema` -- schema with all 3 stores             |
| `defineStore`, `withKeyPath`       | `todosStore` (InlineKey)                            |
| `defineStore`, `withAutoIncrement` | `eventsStore` (GeneratedKey)                        |
| `defineStore` (bare)               | `settingsStore` (ExplicitKey)                       |
| `defineIndex`, `withIndex`         | `byTimestamp`, `byAction` on `eventsStore`          |
| `open`                             | `loadApp` -- opens database, applies schema         |
| `deleteDatabase`                   | "Reset database" button                             |
| `get`                              | `loadData` -- reads theme setting                   |
| `getAll`                           | `loadData` -- loads all todos; `queryAllEventsTask` |
| `getAllKeys`                       | `loadData` -- retrieves todo keys                   |
| `count`                            | `loadData` -- counts events                         |
| `getByIndex`                       | `queryRecentEventsTask`, `queryEventsByActionTask`  |
| `between`, `PosixKey`              | Time range query in `queryRecentEventsTask`         |
| `only`, `StringKey`                | Action filter in `queryEventsByActionTask`          |
| `add`                              | `addTodoTask` -- insert-only                        |
| `put`                              | `toggleTodoTask` -- upsert toggled todo             |
| `addAt`                            | `initDefaults` -- seeds default theme               |
| `putAt`                            | `toggleThemeTask` -- saves theme                    |
| `insert`                           | Event logging in every action task                  |
| `delete`                           | `deleteTodoTask` -- removes a single todo           |
| `deleteMany`                       | "Delete completed" button                           |
| `clear`                            | "Clear todos" button                                |
| `putMany`                          | "Add sample data" -- batch todos                    |
| `putManyAt`                        | "Add sample data" -- batch settings                 |
| `insertMany`                       | "Add sample data" -- batch events                   |

## Project structure

```
todo-app/
  elm.json          -- Elm deps (source-directories includes ../../src)
  package.json      -- JS dependency (@andrewmacmurray/elm-concurrent-task)
  src/
    Main.elm        -- Elm app
    index.js        -- JS entry: registers elm-indexeddb tasks, wires ports
  static/
    index.html      -- HTML shell
    elm.js          -- compiled Elm output (generated)
    main.js         -- bundled JS output (generated)
```
