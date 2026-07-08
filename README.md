# Aerospace

A standalone macOS SwiftUI application that hosts a set of developer **tools**,
selectable from a sidebar. Two tools ship today:

- **Logger** — a local HTTP server that receives, categorizes, persists, and
  displays log events in real time.
- **API Tester** — a lightweight client for building, sending, saving, and
  inspecting HTTP/REST requests (a focused, no-frills alternative to Postman).

Both tools share the app's dependency-free architecture: SwiftUI, a `@MainActor`
store facade per tool, and direct SQLite3 persistence (no third-party packages).

## Logger

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

## API Tester

The second tool builds and sends HTTP requests and inspects the response.

- **Request builder** — name, method (GET/POST/PUT/PATCH/DELETE), URL, dynamic
  query parameters and headers (each row can be enabled/disabled), No-Auth or
  Bearer-token authentication, and a raw or JSON body (with a "Format" button).
- **Send** — executed with `URLSession`; the request duration is measured with a
  monotonic clock. In-flight requests are replaced/cancelled on the next Send.
- **Response viewer** — status pill (coloured by class), duration, byte size,
  and a Body / Headers switcher. JSON bodies are pretty-printed.
- **Persistence** — every request is saved to SQLite and auto-saved as you edit
  (debounced). Requests can be duplicated and deleted from the sidebar.

Query parameters are merged onto the URL via `URLComponents` (encoded once);
`Authorization: Bearer <token>` is added only when a non-empty token is set; and
`Content-Type: application/json` is added for JSON bodies only when you haven't
set one yourself.

Because the app tests arbitrary endpoints (including `http://` and localhost),
App Transport Security is relaxed via `Aerospace/Info.plist`
(`NSAllowsArbitraryLoads`), and the sandbox grants `network.client`.

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
├── AerospaceApp.swift          App entry; owns LogStore + APITesterStore
├── Info.plist                  Bundle keys + ATS (arbitrary loads)
├── Aerospace.entitlements      Sandbox network server + client
├── Models/
│   ├── LogEvent / LogLevel / LogRequest / LogStatistics   (Logger)
│   ├── HTTPMethod / AuthKind / BodyKind / KeyValueItem     (API Tester)
│   └── SavedRequest / APIResponse                          (API Tester)
├── Server/                     Logger inbound server
│   ├── HTTPRequestParser.swift Incremental HTTP/1.1 parser
│   └── HTTPLogServer.swift     Network.framework listener + routing
├── Networking/                 API Tester outbound client
│   ├── RequestBuilder.swift    SavedRequest → URLRequest (pure)
│   └── APIClient.swift         URLSession execution + response mapping
├── Storage/
│   ├── SQLiteLogStore.swift    Logs persistence
│   ├── LogStore.swift          Logger facade (store + server + settings)
│   ├── SQLiteRequestStore.swift  Saved-requests persistence
│   └── APITesterStore.swift    API Tester facade (CRUD + send + auto-save)
└── Views/
    ├── RootView.swift          Tool sidebar → detail
    ├── LoggerToolView.swift    Logger tabs + status bar
    ├── LogsView / StatisticsView / SettingsView / JsonViewer
    ├── APITesterView.swift     HSplitView / VSplitView layout
    ├── RequestListView.swift   Saved-request sidebar
    ├── RequestEditorView.swift Builder form
    ├── KeyValueEditor.swift    Reusable headers/params table
    └── ResponseView.swift      Status / headers / body
```

Each tool has one `@MainActor` store facade (`LogStore`, `APITesterStore`) that
the SwiftUI views bind to directly, rather than per-view ViewModels. Both are
injected as environment objects at the app root.

The API Tester's saved requests are stored in a sibling database,
`…/Application Support/Aerospace/requests.sqlite`, with headers and query
parameters kept as JSON-encoded columns.

## Testing

```sh
xcodebuild -project Aerospace.xcodeproj -scheme Aerospace \
  -configuration Debug -destination 'platform=macOS' test
```

Unit tests cover payload parsing, log-level aliasing, the HTTP request parser
(chunked/pipelined/malformed inputs), the SQLite store (CRUD, filtering,
search, retention), and statistics aggregation.
