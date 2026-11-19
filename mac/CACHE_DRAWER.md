# Cache drawer

A second right-edge seam under the usage rail. It uses the same black/pink palette and the same slide (0.34s, collapse delay 0.22s). It is not a seventh usage slot, and it does not read or replace subscription numbers.

This file is the build and install handoff. Nothing here was installed, and launchd was not touched.

## How this branch is composed

`origin/main` was `1361d96` when this branch was cut (fetched, not force-pushed).

1. `c55d8f1` imports the local dirty UsageRail baseline that was supplied as a read-only bundle. Tracked diff versus `1361d96` matches that bundle for `UsageRailApp.swift` and `collect.py`. It also adds `gemini.svg` and `vertex.svg`. Visible slots stay GPT, Gemini, Grok, Claude, DeepSeek, Endpoint. Height is 420. Slot count is 6. Kimi and Vertex stay compiled and unmounted (`orderOut`). Claude monthly spend and DeepSeek budget display stay. `collect.py` still ends with `_apply_local()` and still does not call `fetch_kimi()`.
2. The cache commit adds `CacheHitCore`, `CacheCompanion.swift`, tests, and four lines in `AppDelegate`: keep a `CacheCompanion` and `attach` / `start` it after the rail exists. `collect.py` is not modified again.

`mac/local.py` is gitignored and is not in this branch. Do not add it. `vertex_status.py` and its tests are not recreated and are not wired.

The live menu-bar binary on the Mac was built from that dirty tree on 2026-11-18. Checking this branch out does not delete gitignored `local.py`. Do not copy a new binary over the running app until you decide to.

## What the drawer shows

Collapsed, it is an 8pt seam, 56pt tall, 8pt below the live rail panel. Expanded, it is 308pt wide, still pinned to the right edge of the rightmost screen, and it lists user turns as local time, turn number, and model. There is no message body.

A turn opens onto per-call rows only when Vertex `conv` equals the session id and `turn` equals `promptIndex`. Sequence is kept:

- A request whose records are exactly prefix/usage pairs, plus at most one trailing prefix, stays as separate calls. A trailing prefix is in progress, not 0%.
- Any other same-request sequence is listed in order and marked 对应关系不明. Rows are not cross-paired, and they are not merged into one call.
- Records with no `req` are not paired with their neighbors.
- `cached_tokens` or `cachedReadTokens` missing or null is 缓存未知, not 0%. A real 0 is 0%.
- Several known calls are summed, then divided once. They are not averaged. Unknown calls are left out of that sum. Session-log totals are not added to Vertex totals, and a `modelCalls > 1` row is not split.
- Rate limit or HTTP 429 without a usable pair stays 限流, not 0%.
- GPT SIWC is parsed with `request_id`. Those rows stay under 未关联. Close timestamps are not treated as a match. `req_id` is not accepted.
- 8317 fingerprints are not the Vertex final-outbound source. They have no `first_diff` in the current shape, so the drawer says the prefix observation is unavailable. It does not say the prefix was unchanged.
- Vertex `first_diff=none` says the observed prefix was unchanged and that a provider can still drop cache. It does not say there was no local change.
- Badges (image count, tool, rewind, model switch, gap) are observations. Short idle is not a TTL verdict. Plain URLs are not read and are not a reason.

If `NOXBUILD_RUNTIME` is unset and there is no settings file, the drawer says 未配置. A missing log says 等待 or 没有. It does not invent live numbers. `USAGE_RAIL_CACHE_SYNTHETIC=1` shows a labeled 合成预览 and does not read logs.

## Paths

All optional, all local:

| Setting | Role |
|---|---|
| `NOXBUILD_RUNTIME` | Runtime root. Wins over the settings file. |
| `~/.cache/usage-rail/cache-companion.json` | `{"runtimeRoot":"..."}` only. The app reads it. It does not create it. |
| `{runtimeRoot}/state/active_session.json` | Session id and transcript path. The transcript must stay inside the runtime root. |
| `NOX_VERTEX_OBSERVE_LOG` | Defaults to `~/Library/Logs/nox-vertex-observe.jsonl`. |
| `NOX_PREFIX_FINGERPRINT_LOG` | Defaults to `~/Library/Logs/nox-prefix-fingerprints.jsonl`. |
| `NOX_SIWC_LOG` | Defaults to `~/Library/Logs/nox-openai-siwc.log`. |

The drawer polls about every 3 seconds, tails new bytes, and keeps a bounded window. Vertex rotation to a single `.1` file is followed. It does not upload anything and it does not call a provider.

## Tests and builds

On this Linux host, `swift test` in `mac/` passed: 31 tests, 0 failures (Swift 6.0.3). That run covers linkage, missing cache versus 0, weighted sums, aggregates, rate limits, badges, rotation, truncation, partial lines, session changes, and privacy sentinels.

The AppKit executable is not part of the Linux package manifest (`#if os(macOS)` in `Package.swift`), so this host did not compile or run the panel. `swiftc -parse` only checked that the Swift files parse. There is no screenshot.

On a Mac, from `mac/`:

```sh
swift test
swift build -c release --product UsageRail
```

That is the remaining validation. Do not `launchctl` bootstrap, kickstart, or replace `mac/.build/release/UsageRail` while the current app is running. After you choose to reload, confirm the six slots are unchanged, the cache seam sits under the rail without covering it, hover slides the list out, and an unset runtime root says 未配置 rather than showing sample turns.

## Known limits

- The usage rail's existing hover pad still reaches 24pt below the rail. The cache panel's visible top is 8pt below the rail, so that pad overlaps the top of the drawer. The cache code does not change the rail's pad. Hovering the rail does not by itself open the cache.
- Joining a user chunk to `turn_completed` follows log order. There is no shared id. The session total stays labeled as a session total.
- A large log is tailed from the end on first open, so older turns can be absent. The status line says so.
- JSON parsing has to read each line in order to drop it. Message text, tool payloads, hashes, and raw lines are not stored and are not drawn.
- 8317 coverage is incomplete and can be older than the current session. The drawer says that.
- Provider gateways were not modified. No extra log fields were added. SIWC still has no session or turn id, so those rows cannot be attached exactly.
