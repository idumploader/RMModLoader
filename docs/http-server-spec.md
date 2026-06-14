# Spec: ModLoader HTTP Server API

Status: **draft**, target branch `feat/http-server`.

## Why

RGSS3 Player ships with a stripped Ruby stdlib that has no `socket`, so
user scripts can't open a network endpoint. We want translator++ (and
other external tools) to be able to query the running game — measure text
width using the actual `Bitmap#text_size`, later render dialog/help
windows, etc.

Putting the socket layer into ModLoader gives Ruby scripts a clean way to
serve HTTP without dragging WinSock/`Win32API` glue into every script.

## Scope

**In scope:**

- A minimal HTTP/1.1 server (request line + headers + body).
- Localhost-only listener (`127.0.0.1`).
- Worker thread in C++ owns the socket and HTTP parsing.
- Ruby side polls a queue and writes responses by request id.
- Binary-safe request and response bodies (PNG etc. in the future).
- Permissive CORS (`Access-Control-Allow-Origin: *`) by default — the
  consumer is an Electron/NW.js app that may do preflight requests.

**Out of scope (for this PR):**

- TLS / HTTPS.
- WebSocket upgrades.
- Chunked transfer / HTTP/2.
- Multiple simultaneous listeners (one port per process).
- Connection keep-alive across requests (`Connection: close` after each).

## Ruby API

All methods live directly on the `ModLoader` module, mirroring existing
conventions (`ModLoader.read_file`, `ModLoader.dump_as_bmp`, etc.).

### `ModLoader.http_listen(port) → true | false`

Starts a background TCP listener on `127.0.0.1:port`. Returns `true` on
success, `false` if the port is busy or the server is already running.
Idempotent: calling it twice with the same port is a no-op and returns
`true`. Calling with a different port while already listening returns
`false` — caller must `http_stop` first.

### `ModLoader.http_stop → nil`

Closes the listener and the worker thread. Drops any in-flight requests
that haven't been responded to (their clients receive a connection
close). Always safe to call.

### `ModLoader.http_poll → String | nil`

Pops the next pending request as a JSON-encoded string, or `nil` if the
queue is empty. Non-blocking. The shape is:

```json
{
  "id":      "1734304019-0042",
  "method":  "POST",
  "path":    "/measure",
  "query":   "",
  "headers": {"content-type": "application/json", "content-length": "73"},
  "body":    "{\"text\":\"Привет\",\"context\":\"dialog\"}"
}
```

- `id` is opaque to Ruby. Treat it as a string token to pass back to
  `http_respond`. Format is "(monotonic-ms)-(per-listener counter)" but
  callers must not parse it.
- `method` and header names are normalized: method uppercase, header keys
  lowercase.
- `body` is the raw request body as a Ruby string. For text bodies it
  carries valid UTF-8; for binary uploads, force encoding on the Ruby
  side (we don't expect those right now).
- Header keys with multiple occurrences are joined with `, ` (RFC 7230).

### `ModLoader.http_respond(id, status, content_type, body) → true | false`

Sends a response and closes the client connection.

- `id` — token from the corresponding `http_poll` result.
- `status` — integer (200, 400, 404, 500…). The C++ side fills in the
  standard reason phrase.
- `content_type` — string, written verbatim into the `Content-Type`
  header (e.g. `"application/json; charset=utf-8"`, `"image/png"`).
- `body` — Ruby String, byte-for-byte body. `Content-Length` is computed
  from `body.bytesize`.

Returns `false` if the id is unknown (already responded, server stopped,
client disconnected). Otherwise `true`.

The response always includes:

```
HTTP/1.1 <status> <reason>\r\n
Content-Type: <content_type>\r\n
Content-Length: <bytesize>\r\n
Access-Control-Allow-Origin: *\r\n
Connection: close\r\n
\r\n
<body>
```

If the request was `OPTIONS`, the server handles it internally (CORS
preflight) without enqueueing — Ruby never sees `OPTIONS` requests.

### `ModLoader.http_inflight_count → Integer`

Returns the number of requests currently held by the server (parsed but
not yet responded to). Useful for the polling loop to decide whether to
keep draining.

## Threading model

```
TCP listener thread (C++)
   ├─ accept() loop
   └─ per-connection thread (C++):
        ├─ read request line + headers + body
        ├─ build JSON, assign id
        ├─ push (id → response slot) into queue
        └─ wait on per-id condition variable
              ↓
Main thread (Ruby, once per frame)
   ├─ ModLoader.http_poll  → request JSON
   ├─ Ruby routes and computes response
   ├─ ModLoader.http_respond(id, status, type, body)
   │     ↓
   └─ C++ writes response to client, signals condvar, closes socket
```

Key invariants:

- Bitmap / Window / Sprite / Graphics calls happen only on the main
  thread. Ruby owns this by polling.
- The connection thread blocks on a condvar bound to its id; if Ruby
  never responds (or calls `http_stop`), the thread is woken with a 500
  body and exits.
- No Ruby callbacks fire from C++ threads. All Ruby execution is driven
  by `http_poll` / `http_respond` calls from the game's main thread.

## Implementation notes

### Dependencies

- **cpp-httplib** (header-only, MIT). Added to `vcpkg.json` as
  `cpp-httplib`, linked via `target_link_libraries(... httplib::httplib)`
  in `CMakeLists.txt`. Handles request parsing, header dedup, keep-alive,
  thread pool, CORS preflight, binary bodies.
- `nlohmann/json` (already present) — JSON envelope construction.

### Files

- `src/ModLoader/Hooks/HttpServerHooks.hpp` — public entrypoint
  declaration (`apply_http_server_hooks()`).
- `src/ModLoader/Hooks/HttpServerHooks.cpp` — `HttpServer` singleton
  (server lifecycle, pending map, ready queue) + `HttpServerModule` Ruby
  shims + `apply_http_server_hooks` wiring.
- `src/ModLoader/Hooks.hpp` — `#include` and append to
  `hooks_appliers` array.
- `CMakeLists.txt` — `find_package(httplib CONFIG REQUIRED)`, add
  `HttpServerHooks.cpp` to ModLoader sources, link `httplib::httplib`.

### Architecture

```cpp
httplib::Server svr;
svr.set_default_headers({{"Access-Control-Allow-Origin", "*"}});
svr.Options(R"(.*)", /* CORS preflight, handled before queue */);

auto catchall = [](const Request& req, Response& res) {
    auto slot = make_shared<ResponseSlot>();
    auto id = generate_id();
    queue.push(build_json(id, req));
    pending[id] = slot;

    unique_lock lk(slot->mutex);
    slot->cv.wait_for(lk, 30s, [&] { return slot->ready; });
    res.status = slot->status;
    res.set_content(slot->body, slot->content_type);
};
svr.Get(R"(.*)", catchall);
svr.Post(R"(.*)", catchall);
// ... PUT, DELETE
svr.listen("127.0.0.1", port);  // blocks; run on a dedicated thread
```

cpp-httplib runs each request handler on its own worker thread (its
internal pool). The handler builds a JSON envelope, pushes it onto the
ready queue, and blocks on a condvar until `respond()` is called from
Ruby. Timeout of 30s prevents wedged requests from sitting forever.

### Request envelope

JSON shape pushed onto the queue and returned by `http_poll`:

```cpp
nlohmann::json env = {
    {"id",      id},          // "<steady_clock-ns>-<counter>"
    {"method",  req.method},  // "GET" / "POST" / ...
    {"path",    req.path},
    {"query",   ""},          // TODO: reassemble req.params if needed
    {"headers", lowercased_deduped_headers},
    {"body",    req.body},    // raw bytes; can be binary
};
return rb_str_new(env.dump().c_str(), env.dump().size());
```

Ruby parses this with the existing minimal JSON helper. No `rb_hash_new`
symbol resolution required on the C++ side.

### Ruby integer / string conversions

All needed primitives are already in `RMGlobal.hpp` / `Ruby.hpp`:

- `rb_num2ull(value)` — Ruby Fixnum/Bignum → `uint64_t` (used for
  `port` and `status` args).
- `rb_make_number(long)` — C int → Ruby Fixnum (for
  `http_inflight_count` return).
- `rb_get_string_data(&val)` — Ruby String → `const char*`. Safe for
  ASCII fields (`id`, `content_type`).
- `rb_str_value(val)` — Ruby String → `std::string_view` with length.
  Binary-safe for heap-allocated strings (any body bigger than ~11 bytes,
  which is always the case for non-trivial responses).
- `rb_str_new(ptr, len)` — C bytes → Ruby String, binary-safe.
- `ruby_true`, `ruby_false`, `ruby_nil` constants.

**No new ModLoader symbols need to be added.** If we later want fully
binary-safe small responses (≤ 11 bytes), we'd add a `rb_str_value_safe`
that uses the embed-length encoding properly — out of scope right now.

### Ruby method registration

```cpp
void apply_http_server_hooks() {
    mod_loader->add_preinit_handler([] {
        mod_loader->register_ruby_method("http_listen",         HttpServerModule::listen);
        mod_loader->register_ruby_method("http_stop",           HttpServerModule::stop);
        mod_loader->register_ruby_method("http_poll",           HttpServerModule::poll);
        mod_loader->register_ruby_method("http_respond",        HttpServerModule::respond);
        mod_loader->register_ruby_method("http_inflight_count", HttpServerModule::inflight_count);
    });
}
```

## Example Ruby usage

```ruby
# Boot
ModLoader.http_listen(27420)

# Drain queue every frame
class Scene_Base
  alias :http_orig_update_basic :update_basic
  def update_basic
    http_orig_update_basic
    while (req_json = ModLoader.http_poll)
      handle(req_json)
    end
  end
end

def handle(json_str)
  req = JsonMini.parse(json_str)
  case [req["method"], req["path"]]
  when ["GET", "/ping"]
    ModLoader.http_respond(req["id"], 200, "text/plain", "pong")
  when ["POST", "/measure"]
    body = MeasureEndpoint.run(req["body"])
    ModLoader.http_respond(req["id"], 200, "application/json", body)
  else
    ModLoader.http_respond(req["id"], 404, "text/plain", "not found")
  end
end
```

## Error handling

- Port busy on `http_listen`: log via `ModLoader.log`, return `false`.
- Worker thread exception: log full stack, send 500 to current client,
  continue accepting new connections. Don't crash the game.
- Ruby never responds for an id: 504 to the client after the timeout,
  drop the entry. Log a warning.
- Invalid id to `http_respond` (already responded / unknown): return
  `false`. No exception raised on the Ruby side.

## Open questions

1. **Auth.** Do we want to gate the server behind a token? Localhost-only
   binding limits exposure to local processes already; for translator++
   that's probably enough. Leaving unauthenticated for now.
2. **Port discovery.** Hardcoded `27420` in the consumer (LinesChecker)
   is brittle if another process grabs the port. Worth adding a CLI flag
   / `mod_loader.json` key (`http_server_port`) later.
3. **Stream endpoints.** If we ever want push (live render preview during
   typing), the cleanest extension is a `/stream/...` GET that holds the
   connection open and writes `text/event-stream` frames. Server-Sent
   Events fit our use case better than WebSocket — they need no separate
   handshake handling in the C++ HTTP path. Out of scope for this PR.
4. **Body size cap for `http_respond`.** Should there be one? PNG of the
   game window is ~50 KiB, totally fine. Future render of bigger
   surfaces? Soft cap (logged warning) at 16 MiB seems reasonable, with
   a hard cap matching the connection thread's send buffer behaviour.
