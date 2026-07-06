# Aerospace

A standalone macOS SwiftUI application that runs a local HTTP server, accepts
log events from any application on the machine, categorizes and persists them
to SQLite, and displays them in a real-time interface.

## Features

- **Local HTTP server** on a configurable port (default `57333`), built on
  Apple's `Network` framework — **no third-party dependencies**.
- **Three-argument logging API**: `arg1` → category, `arg2` → subcategory,
  `arg3` → arbitrary JSON payload.
- **SQLite persistence** via the system SQLite3 library.
- **Real-time UI** with three tabs:
  - **Logs** — category sidebar, subcategory filter chips, searchable and
    level-filtered log list, and a pretty-printed JSON detail viewer.
  - **Statistics** — summary tiles and Swift Charts (activity per minute,
    logs by category, level breakdown, top subcategories).
  - **Settings** — server port, log retention / auto-purge, JSON & CSV
    export, and clear-all.
- **Server status bar** with live state and start/stop controls.

## Requirements

- macOS 26.1+
- Xcode 26+

## Building & Running

```sh
xcodebuild -project Aerospace.xcodeproj -scheme Aerospace \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Aerospace-*/Build/Products/Debug/Aerospace.app
```

Or open `Aerospace.xcodeproj` in Xcode and press Run. The HTTP server starts
automatically on launch.

The App Sandbox is enabled; `Aerospace.entitlements` grants the
`com.apple.security.network.server` entitlement so the app can listen for
incoming connections.

## Logging API

### Endpoint

```
POST http://localhost:57333/log
Content-Type: application/json
```

### Payload

```json
{
  "arg1": "Authentication",
  "arg2": "Login",
  "arg3": {
    "userId": 123,
    "status": "success",
    "token": "xyz"
  }
}
```

`arg3` may be a JSON object, array, string, number, or boolean. Objects are
inspected for these optional fields (which may also appear at the top level):

| Field         | Meaning                                                                                                  |
| ------------- | -------------------------------------------------------------------------------------------------------- |
| `level`       | `debug` / `info` / `warning` / `error` / `critical` (aliases accepted)                                   |
| `sessionId`   | Session identifier (`session_id` also accepted)                                                          |
| `application` | Source application name (`app` also accepted)                                                            |
| `component`   | Where in the app the log originated, e.g. a view/screen name like `"Home screen"` (`comp` also accepted) |

### Responses

| Status | When                                               |
| ------ | -------------------------------------------------- |
| `200`  | Log accepted — body `{"status":"ok","id":"…"}`     |
| `400`  | Missing `arg1`/`arg2`, empty body, or invalid JSON |
| `404`  | Unknown route                                      |

A `GET /health` endpoint returns `{"status":"healthy"}`.

### Examples

**curl**

```sh
curl -X POST http://localhost:57333/log \
  -H 'Content-Type: application/json' \
  -d '{"arg1":"Payments","arg2":"Refund","arg3":{"amount":50,"level":"warning"}}'
```

**Swift client helper**

```swift
func Log(_ category: String, _ subCategory: String, _ payload: [String: Any]) {
    let body: [String: Any] = ["arg1": category, "arg2": subCategory, "arg3": payload]
    var request = URLRequest(url: URL(string: "http://localhost:57333/log")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request).resume()
}

Log("Authentication", "Login", ["userId": 123, "status": "success"])
```

**Node.js**

```js
fetch("http://localhost:57333/log", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    arg1: "API",
    arg2: "Request",
    arg3: { path: "/users" },
  }),
});
```

## Storage

Logs are stored at:

```
~/Library/Containers/com.networkten.epg.Aerospace/Data/Library/Application Support/Aerospace/logs.sqlite
```

Schema:

```sql
CREATE TABLE logs (
    id TEXT PRIMARY KEY,
    timestamp REAL NOT NULL,
    category TEXT NOT NULL,
    subcategory TEXT NOT NULL,
    payload TEXT NOT NULL,
    level TEXT NOT NULL DEFAULT 'info',
    session_id TEXT,
    application TEXT,
    component TEXT
);
```

## Project Structure

```
Aerospace/
├── AerospaceApp.swift          App entry; owns the shared LogStore
├── ContentView.swift           TabView + server status bar
├── Aerospace.entitlements      Sandbox network-server entitlement
├── Models/
│   ├── LogEvent.swift          Stored log representation
│   ├── LogLevel.swift          Severity levels
│   ├── LogRequest.swift        Incoming-payload → LogEvent parser
│   └── LogStatistics.swift     Aggregation for the Statistics tab
├── Server/
│   ├── HTTPRequestParser.swift Incremental HTTP/1.1 parser
│   └── HTTPLogServer.swift     Network.framework listener + routing
├── Storage/
│   ├── SQLiteLogStore.swift    Thread-safe SQLite persistence
│   └── LogStore.swift          Observable app state (store + server + settings)
└── Views/
    ├── LogsView.swift
    ├── StatisticsView.swift
    ├── SettingsView.swift
    └── JsonViewer.swift
```

`LogStore` doubles as the view-model layer: the SwiftUI views bind directly to
its published state rather than to separate per-tab view-model objects.

## Testing

```sh
xcodebuild -project Aerospace.xcodeproj -scheme Aerospace \
  -configuration Debug -destination 'platform=macOS' test
```

Unit tests cover payload parsing, log-level aliasing, the HTTP request parser
(chunked/pipelined/malformed inputs), the SQLite store (CRUD, filtering,
search, retention), and statistics aggregation.
