// IndexedDB tasks for elm-concurrent-task
//
// Usage:
//   import * as ConcurrentTask from "@andrewmacmurray/elm-concurrent-task";
//   import { createTasks } from "elm-indexeddb";
//   ConcurrentTask.register({
//     tasks: createTasks(),
//     ports: { send: app.ports.send, receive: app.ports.receive },
//   });

export function createTasks() {
  const databases = new Map();

  return {
    "indexeddb:open": (args) => handleOpen(databases, args),
    "indexeddb:deleteDatabase": (args) => handleDeleteDatabase(databases, args),
    "indexeddb:get": (args) => handleGet(databases, args),
    "indexeddb:getAll": (args) => handleGetAll(databases, args),
    "indexeddb:getAllKeys": (args) => handleGetAllKeys(databases, args),
    "indexeddb:count": (args) => handleCount(databases, args),
    "indexeddb:put": (args) => handlePut(databases, args),
    "indexeddb:add": (args) => handleAdd(databases, args),
    "indexeddb:delete": (args) => handleDelete(databases, args),
    "indexeddb:clear": (args) => handleClear(databases, args),
    "indexeddb:putMany": (args) => handlePutMany(databases, args),
    "indexeddb:insertMany": (args) => handleInsertMany(databases, args),
    "indexeddb:deleteMany": (args) => handleDeleteMany(databases, args),
  };
}

// --- Key encoding/decoding ---

function decodeKey(encoded) {
  switch (encoded.type) {
    case "string":
      return encoded.value;
    case "int":
      return encoded.value;
    case "float":
      return encoded.value;
    case "posix":
      return new Date(encoded.value);
    case "compound":
      return encoded.value.map(decodeKey);
    default:
      throw new Error("Unknown key type: " + encoded.type);
  }
}

function encodeKey(native) {
  if (native instanceof Date) {
    return { type: "posix", value: native.getTime() };
  } else if (typeof native === "string") {
    return { type: "string", value: native };
  } else if (typeof native === "number") {
    if (Number.isInteger(native)) {
      return { type: "int", value: native };
    } else {
      return { type: "float", value: native };
    }
  } else if (Array.isArray(native)) {
    return { type: "compound", value: native.map(encodeKey) };
  } else {
    throw new Error("Unsupported key type: " + typeof native);
  }
}

// --- Key range decoding ---

function decodeKeyRange(encoded) {
  switch (encoded.type) {
    case "only":
      return IDBKeyRange.only(decodeKey(encoded.key));
    case "lowerBound":
      return IDBKeyRange.lowerBound(decodeKey(encoded.key), encoded.open);
    case "upperBound":
      return IDBKeyRange.upperBound(decodeKey(encoded.key), encoded.open);
    case "bound":
      return IDBKeyRange.bound(
        decodeKey(encoded.lower),
        decodeKey(encoded.upper),
        encoded.lowerOpen,
        encoded.upperOpen,
      );
    default:
      throw new Error("Unknown key range type: " + encoded.type);
  }
}

// --- Error normalization ---

function normalizeError(error) {
  const msg = error?.message || String(error);
  if (error?.name === "ConstraintError") {
    return { error: "ALREADY_EXISTS" };
  }
  if (error?.name === "QuotaExceededError") {
    return { error: "QUOTA_EXCEEDED" };
  }
  if (
    error?.name === "TransactionInactiveError" ||
    error?.name === "AbortError"
  ) {
    return { error: "TRANSACTION_ERROR:" + msg };
  }
  return { error: "DATABASE_ERROR:" + msg };
}

// --- Helpers ---

function getDb(databases, name) {
  const db = databases.get(name);
  if (!db) {
    return { error: "DATABASE_ERROR:Database '" + name + "' is not open" };
  }
  return db;
}

function readOp(databases, dbName, storeName, fn) {
  const db = getDb(databases, dbName);
  if (db.error) return db;
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(storeName, "readonly");
      const store = tx.objectStore(storeName);
      fn(store, resolve);
      tx.onerror = () => resolve(normalizeError(tx.error));
    } catch (e) {
      resolve(normalizeError(e));
    }
  });
}

function writeOp(databases, dbName, storeName, fn) {
  const db = getDb(databases, dbName);
  if (db.error) return db;
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(storeName, "readwrite");
      const store = tx.objectStore(storeName);
      fn(store, tx, resolve);
      tx.onerror = () => resolve(normalizeError(tx.error));
    } catch (e) {
      resolve(normalizeError(e));
    }
  });
}

// --- Task handlers ---

function handleOpen(databases, { name, version, stores }) {
  return new Promise((resolve) => {
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

      // Create or verify stores in schema
      for (const storeDef of stores) {
        let objectStore;
        if (db.objectStoreNames.contains(storeDef.name)) {
          // Store exists — verify keyPath matches
          objectStore = tx.objectStore(storeDef.name);
          const existingKeyPath = objectStore.keyPath;
          const wantedKeyPath = storeDef.keyPath;
          if (
            JSON.stringify(existingKeyPath) !== JSON.stringify(wantedKeyPath)
          ) {
            schemaError =
              "DATABASE_ERROR:Store '" +
              storeDef.name +
              "' has keyPath '" +
              JSON.stringify(existingKeyPath) +
              "' but schema expects '" +
              JSON.stringify(wantedKeyPath) +
              "'. Use a new store name or delete the database.";
            tx.abort();
            return;
          }
        } else {
          // Create new store
          const options = {};
          if (storeDef.keyPath !== null) {
            options.keyPath = storeDef.keyPath;
          }
          if (storeDef.autoIncrement) {
            options.autoIncrement = true;
          }
          objectStore = db.createObjectStore(storeDef.name, options);
        }

        // Sync indexes
        const schemaIndexNames = (storeDef.indexes || []).map((i) => i.name);

        // Delete indexes not in schema
        for (const existing of Array.from(objectStore.indexNames)) {
          if (!schemaIndexNames.includes(existing)) {
            objectStore.deleteIndex(existing);
          }
        }

        // Create indexes in schema that don't exist yet
        for (const indexDef of storeDef.indexes || []) {
          if (!objectStore.indexNames.contains(indexDef.name)) {
            objectStore.createIndex(indexDef.name, indexDef.keyPath, {
              unique: indexDef.unique,
              multiEntry: indexDef.multiEntry,
            });
          }
        }
      }
    };

    request.onsuccess = (event) => {
      databases.set(name, event.target.result);
      resolve({});
    };

    request.onerror = (event) => {
      if (schemaError) {
        resolve({ error: schemaError });
      } else {
        resolve(normalizeError(event.target.error));
      }
    };
  });
}

function handleDeleteDatabase(databases, { db: dbName }) {
  const existing = databases.get(dbName);
  if (existing) {
    existing.close();
    databases.delete(dbName);
  }
  return new Promise((resolve) => {
    const request = indexedDB.deleteDatabase(dbName);
    request.onsuccess = () => resolve({});
    request.onerror = () => resolve(normalizeError(request.error));
  });
}

function handleGet(databases, { db: dbName, store: storeName, key }) {
  return readOp(databases, dbName, storeName, (store, resolve) => {
    const request = store.get(decodeKey(key));
    request.onsuccess = () => {
      resolve(request.result === undefined ? null : request.result);
    };
  });
}

function handleGetAll(databases, args) {
  const { db: dbName, store: storeName } = args;
  return readOp(databases, dbName, storeName, (store, resolve) => {
    const target = args.index ? store.index(args.index) : store;
    const range = args.range ? decodeKeyRange(args.range) : undefined;
    const keysReq = target.getAllKeys(range);
    const valuesReq = target.getAll(range);
    let keys = null;
    let values = null;
    function tryResolve() {
      if (keys !== null && values !== null) {
        resolve(keys.map((k, i) => ({ key: encodeKey(k), value: values[i] })));
      }
    }
    keysReq.onsuccess = () => {
      keys = keysReq.result;
      tryResolve();
    };
    valuesReq.onsuccess = () => {
      values = valuesReq.result;
      tryResolve();
    };
  });
}

function handleGetAllKeys(databases, args) {
  const { db: dbName, store: storeName } = args;
  return readOp(databases, dbName, storeName, (store, resolve) => {
    const target = args.index ? store.index(args.index) : store;
    const range = args.range ? decodeKeyRange(args.range) : undefined;
    const request = target.getAllKeys(range);
    request.onsuccess = () => resolve(request.result.map(encodeKey));
  });
}

function handleCount(databases, args) {
  const { db: dbName, store: storeName } = args;
  return readOp(databases, dbName, storeName, (store, resolve) => {
    const target = args.index ? store.index(args.index) : store;
    const range = args.range ? decodeKeyRange(args.range) : undefined;
    const request = target.count(range);
    request.onsuccess = () => resolve(request.result);
  });
}

function handlePut(databases, { db: dbName, store: storeName, value, key }) {
  return writeOp(databases, dbName, storeName, (store, _tx, resolve) => {
    const request =
      key !== undefined ? store.put(value, decodeKey(key)) : store.put(value);
    request.onsuccess = () => resolve(encodeKey(request.result));
  });
}

function handleAdd(databases, { db: dbName, store: storeName, value, key }) {
  return writeOp(databases, dbName, storeName, (store, _tx, resolve) => {
    const request =
      key !== undefined ? store.add(value, decodeKey(key)) : store.add(value);
    request.onsuccess = () => resolve(encodeKey(request.result));
  });
}

function handleDelete(databases, args) {
  const { db: dbName, store: storeName } = args;
  return writeOp(databases, dbName, storeName, (store, _tx, resolve) => {
    const target = args.range
      ? decodeKeyRange(args.range)
      : decodeKey(args.key);
    const request = store.delete(target);
    request.onsuccess = () => resolve({});
  });
}

function handleClear(databases, { db: dbName, store: storeName }) {
  return writeOp(databases, dbName, storeName, (store, _tx, resolve) => {
    const request = store.clear();
    request.onsuccess = () => resolve({});
  });
}

function handlePutMany(databases, { db: dbName, store: storeName, entries }) {
  return writeOp(databases, dbName, storeName, (store, tx, resolve) => {
    for (const entry of entries) {
      if (entry.key !== undefined) {
        store.put(entry.value, decodeKey(entry.key));
      } else {
        store.put(entry.value);
      }
    }
    tx.oncomplete = () => resolve({});
  });
}

function handleInsertMany(databases, { db: dbName, store: storeName, values }) {
  return writeOp(databases, dbName, storeName, (store, tx, resolve) => {
    const keys = [];
    for (const value of values) {
      const request = store.put(value);
      request.onsuccess = () => keys.push(encodeKey(request.result));
    }
    tx.oncomplete = () => resolve(keys);
  });
}

function handleDeleteMany(databases, { db: dbName, store: storeName, keys }) {
  return writeOp(databases, dbName, storeName, (store, tx, resolve) => {
    for (const key of keys) {
      store.delete(decodeKey(key));
    }
    tx.oncomplete = () => resolve({});
  });
}
