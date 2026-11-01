# Slave Card — Handoff to Hoshi

## Executive Summary

This handoff describes the repository at baseline `c12400b594d48a4f21562ff3ddfff59b9f95d4d7` on `main`, tracking `origin/main`. The worktree was clean before handoff preparation. No gameplay source was changed for this handoff.

The project is a Godot 4.7.2 card game. Browser clients use committed Godot Web exports served by a Render Static Site; multiplayer traffic goes through a Node WebSocket proxy to a Godot authoritative server. The server keeps room and match state in memory. Current server startup and main-scene smoke checks passed. The broad validation runner currently exits with 99 assertion failures and an uncaught trade-test error. Most failures are clustered around expectations that conflict with current rules or presentation; they still need triage rather than being treated as harmless.

**Important rule conflict:** the required handoff contract says Straight and Straight Flush are exactly five cards, but current `game_rules.gd` accepts consecutive sequences of 3–8 cards. This is an implementation discrepancy against the supplied DO NOT REGRESS contract and must be resolved by Hoshi before anyone changes gameplay. The prior source history and tests also contain 3/4-card assumptions, so do not infer the intended rule from those tests.

## Current Baseline

| Item | Verified state |
|---|---|
| Branch | `main` |
| Exact handoff baseline | `c12400b594d48a4f21562ff3ddfff59b9f95d4d7` (`c12400b`) |
| Upstream | `origin/main` |
| Initial worktree | Clean (`git status --short` empty) |
| Latest relevant commit | `c12400b Fix card rules, exchange flow, and online UI` |
| Godot | `4.7.2.stable.official.ed1daf0bf`; project declares Godot 4.7 |
| Render server service | `slave-card-server` (Docker web service, Free, one instance) |
| Render client service | `slave-card-client` (Static Site publishing `web-build/`) |
| Public WebSocket URL | `wss://slave-card-server.onrender.com` |
| Web client URL | Not recorded explicitly in repository; confirm canonical URL in Render dashboard. The service name alone is not treated as proof of its URL. |
| Local desktop WebSocket | `ws://127.0.0.1:10000` by default |
| Godot executable used | `C:\Users\padet_s\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe` |

Recent history relevant to the baseline includes `dcebe81` (production server startup compilation), `397ca78` / `4d40da3` / `2982d7e` (GameState construction/loading), `f422d5b` (WebSocket health probe), `2a42549` (headless-safe SfxManager), `c100eb8` (center pile during animation), `2ec0d02` (multi-card layout), and `c12400b` (current rules, exchange, online UI changes). `web-build/index.html` and `web-build/index.pck` are tracked. The current history proves Web exports were refreshed in several commits, but the inspected history did not establish the exact root cause/commit for every incident example in the request; see Fixed Incident History.

## Architecture

### Client and server path

```text
Browser / Godot Web client
  -> Render Static Site (committed web-build/)
  -> wss://slave-card-server.onrender.com/
  -> Render TLS termination and public Node proxy (0.0.0.0:$PORT)
  -> WebSocket forwarded to Godot at 127.0.0.1:$GODOT_PORT (default 10001 in Docker)
  -> Godot ServerNetworkEndpoint / RoomService
  -> authoritative room, round, player, turn, bot, and card state
```

`Dockerfile` launches `server/render_proxy.js`. The proxy owns the public HTTP/WebSocket socket and starts Godot headlessly as a child process. Godot binds only to loopback in the container. The proxy accepts WebSocket upgrades on `/`; its `/health` response reports backend readiness, and returns 503 until Godot has printed `GODOT_BACKEND_READY` and remains alive. A Node-only process is not considered ready.

`NetworkProtocol` defines message names and payload wrapping. `NetworkEndpoint` is the reliable RPC base; the client endpoint connects, while the server endpoint listens and hands messages to `RoomService`. Gameplay and lobby state are server-authoritative; clients submit intents and consume snapshots/events.

### State and persistence

Rooms and game/match state live in process memory in the server-side room and match objects. No persistent database or save-state implementation was found in the inspected paths. A server restart/replacement loses active rooms and matches and drops current WebSocket connections. Render is configured for one server instance; scaling out requires shared state or deliberate session routing.

## Gameplay Rules

This section distinguishes observed code from the handoff contract. Current authoritative implementation is in `scripts/game/game_rules.gd` and `scripts/game/game_state.gd`.

### Verified implementation at baseline

- Match/game setup supports 2–12 players. `deck_factory.gd` uses one 52-card deck through six players and two decks above six.
- Rank order is `3, 4, 5, 6, 7, 8, 9, 10, J, Q, K, A, 2`; suit order is Clubs < Diamonds < Hearts < Spades.
- Singles contain one card. Pair, Triple (three of a kind), and Four of a Kind are equal-rank groups of 2, 3, and 4 cards respectively.
- Straight and Straight Flush are currently consecutive, non-repeating rank sequences from 3 through 8 cards. Two is allowed as the top endpoint; the sequence cannot wrap.
- Straight Flush is same-suit consecutive ranks. For the same count it ranks above ordinary Straight; count is compared first. Remaining ties use high rank and then the implementation's suit comparison.
- Pair/Four belong to the even-card family. Single/Triple belong to the odd-card family. Straight/Straight Flush use the actual count parity. `can_beat` rejects different parity families.
- When the current combination is Triple or Straight Flush, the response must have that exact type. When it is Pair or Four of a Kind, response must be Pair or Four. Other combinations can cross types if they remain in the same family and compare higher.
- A new trick accepts any valid lead. Passing is allowed. `GameState` advances past passed/finished players and resets the trick when no eligible player remains; the last player who played leads the reset trick. Current code allows the sole remaining active player to continue until they finish, rather than auto-finishing them merely because only one active player remains.
- `game_state.gd` is the rules authority for turn legality and pass/reset progression; bots request legal combinations through `GameRules`.
- Duplicate cards from separate decks retain deck identity in the ID (`rank:suit:deck_index`), but strength/comparison ignores deck index. Identical rank+suit cards are not stronger because of deck identity.

### Starter and duplicate 3♣

First-round starter selection checks for 3♣. If exactly one player has it, that player starts. With duplicated 3♣ in the two-deck game, the server enters a tie-break/RPS flow instead of allowing deck identity to decide strength. Bots choose on the server. The source and validation runner cover the duplicate-card/tie-break path; confirm full online behavior with the network smoke matrix below.

### Contract discrepancy requiring triage

The required product contract in this handoff is **Straight = exactly 5 cards** and **Straight Flush = exactly 5 cards**. The implementation currently allows 3–8, and the validation runner has expectations for 3/4-card sequences. This is not silently resolved here. Hoshi should establish the intended exact rule and then align source, tests, and user-facing rules together. Other pair-sequence / even-family behavior is governed by the current parity rule above; do not redesign Pair logic casually.

## Match / Round System

- `MatchState` accepts match lengths of 4, 8, or 12 rounds and player counts of 2–12.
- Per-round points are `player_count - place - 1`: first place receives `n-1`, last receives zero. Ranking uses total points, then number of first places, then second places, then best final position, then player index for deterministic ordering.
- The server owns start, next-round progression, match results, and rematch/continue decisions. The current code paths were inspected; a full production rematch cycle was not exercised in this handoff.
- `RoleSystem` assigns King to the winner and maps later finish positions to roles. A former King who does not win is demoted to Slave 1; current role displacement is handled by the role map. Role tests exist in the validation runner.
- Card exchange is server-managed. For 2–3 players King/Slave 1 exchange two; the 3-player case also includes Queen/Slave 1 exchange one. For 4–6, King/Slave 1 exchange two and Queen/Slave 2 exchange one. For 7+, King/Slave 1 exchange three, Queen/Slave 2 exchange two, Seven/Slave 3 exchange one. Slaves return the mandatory highest cards; upper roles choose cards to return. Human participants confirm their selection; bots select automatically. Incoming cards are included in exchange state for preview.
- Bots select legal combinations and generally prefer low legal plays while attempting an immediate finish when possible. Bot strategy details are in `bot_brain.gd`.
- Lobby disconnection and active-match disconnection are separate paths. A lobby guest is removed; host departure closes the lobby room. An active-match disconnect/forfeit is handled separately, with the disconnected player represented as a bot in a later round. Verify exact user experience after future changes.

## Multiplayer Lobby

`RoomService` handles Create Room, Join Room, ready state, Start Game, optional bot fill, seat swapping, leaving, and server snapshots/events. Start is host-authorized and server readiness is checked. Start-game timeout/error feedback is present in the multiplayer UI. Guest lobby leave removes the player and updates lobby state; host leave closes the lobby room. Active-match disconnect/forfeit does not use the lobby-leave behavior.

Recent `2c406f4` changed lobby presence synchronization and timeout behavior and also refreshed both tracked Web entry artifacts. These behaviors should continue to be checked with multiple clients, not inferred from a single local scene.

## RPS / Starter Flow

RPS/tie-break appears when starter selection needs a tie-break, including the duplicate 3♣ case. The online flow renders card backs and then reveals choices/result; bots are resolved server-side. Host can continue/start the round after the result; guests wait for the authoritative transition. A tie repeats the tie-break. The online RPS branch creates the same `TablePresentation` system used by gameplay and places a centered RPS overlay within the table zone. This is verified in `multiplayer_flow.gd`; visual behavior at all resolutions was not exhaustively checked.

## UI / Presentation

- `TableLayout` uses a 1920×1080 reference canvas, with top HUD `(0,0,1920,96)`, table zone `(560,96,800,800)`, and bottom HUD `(0,896,1920,184)`, scaled to the viewport.
- The local player is placed South. The table presentation computes other seats around an ellipse; exact test expectations for clockwise/next-player order currently fail and require triage.
- Current table/background art is used behind seat panels and the central play area. Seat panels show player identity, remaining card count, and status. Role badges are sibling elements to the right of the seat panel (not embedded in the panel).
- The hand and action controls occupy the bottom HUD. `CardView` is shared for hand, pile, and animation cards and handles card face, rank/suit display, selection, and hover.
- Center pile tracks the current trick/play history. During a play animation, previous pile cards remain visible. Multi-card flight and final pile use the shared landing layout helper to preserve formation and reduce overlap.
- Layout and animation assertions exist, but the current validation runner reports seat mapping and one Straight cluster failure; see Known Issues.

## Audio Rules

The requested SFX contract is narrow: `flip-card.mp3` is only used for a valid card select/deselect, exchange selection, and a committed valid card play. It is not for generic UI click, shuffle, deal, pass, ready, or start. Current `SfxManager` implements click/shuffle as no-ops and supports card select/play sound events; inspect exchange selection before extending audio behavior. Audio is lazy-loaded only when enabled. Audio is disabled for headless/dedicated-server execution, avoiding MP3 import/preload dependency on the server.

## Production / Deployment

- Render's static client serves the committed `web-build/` directory. UI/gameplay source changes do not reach production until the Web export is regenerated and committed. `web-build/index.pck` is critical alongside `index.html` and the other export files.
- `render.yaml` uses the committed export; the static build command only prints a message and does not run Godot. The web client hardcodes the production WebSocket URL `wss://slave-card-server.onrender.com`; desktop uses localhost/config.
- Server source changes require a Render server redeploy. The Docker image contains Node 22 and Godot 4.7.2, then launches the proxy and Godot backend.
- Health readiness must track Godot backend readiness, not just proxy liveness. The current proxy waits for `GODOT_BACKEND_READY` and returns 503 before readiness. Do not add periodic fake WebSocket probes.
- Clean-cache Linux behavior matters. Godot global script class caches generated in an editor checkout may hide server loading failures. Keep explicit/dynamic critical script loading valid and verify with a clean Linux environment/cache.
- Headless/dedicated server must remain safe with audio autoloads and must not eagerly load/import MP3 resources.
- Render runs one instance and stores sessions in memory. Deploy/restart terminates current sockets and loses rooms/matches; clients must reconnect.
- The export tool is `tools/export_web.py`; it accepts `GODOT_BIN` and optionally `SLAVE_CARD_SERVER_URL`, temporarily writes the URL config for export, and restores the original config afterward.

## Fixed Incident History

The following are supported by the current history and implementation. “Fixed” means the cited change is present at the current baseline; production runtime was not independently queried.

| Incident | Evidence / fix | Status |
|---|---|---|
| Server startup compilation / proxy readiness | `dcebe81` modified `room_service.gd`, `render_proxy.js`, and added startup regression coverage. Current proxy gates readiness on Godot startup output. | FIXED in current source; clean-cache Linux deploy still needs repeat verification. |
| GameState construction and class loading in production | `4d40da3`, `2982d7e`, `397ca78`; explicit factory/loading path and startup runner verify GameState construction and next round. | FIXED in current source; do not rely on editor cache. |
| WebSocket readiness probe | `f422d5b`; current `/health` is HTTP readiness based on Godot process/backend readiness, not a malformed WebSocket probe. | FIXED in current source. |
| Lobby presence / start timeout | `2c406f4`; updates room service, protocol, client flow, tests, and web export. | FIXED in current source; multi-client regression remains useful. |
| Headless SfxManager preload | `2a42549`; audio is disabled/lazy for headless and dedicated-server execution. | FIXED in current source. |
| Center pile disappearing during play animation | `c100eb8`; pile visibility retained during the flight and regression coverage added. | FIXED in current source. |
| Multi-card landing overlap | `2ec0d02`; card view/table layout updated to share a deterministic multi-card formation and export refreshed. | FIXED in current source; visual checks still needed. |
| Stale web export / source without `index.pck` | Several commits, including `b329a76`, `2c406f4`, `c100eb8`, and `2ec0d02`, update tracked `index.html` and `index.pck` together. The exact historical incident/root-cause commit was not verified in the inspected history. | Current deployment rule verified; original incident details unverified. |
| Start Game lambda capture freed | Not confirmed in inspected commit subjects/diffs or current source review. | Historical example unverified; do not label fixed without evidence. |

## Tests and Validation

### Results from this handoff inspection

- `tests/validation_runner.tscn`: **failed** with 99 assertion failures and an uncaught runtime error in `tests/validation_runner.gd:498` (`_test_trade_rules`, indexing transfer 0 when no completed transfer existed). Several trade assertions expect slaves to be automatically ready, conflicting with current human Slave confirmation. Full issue clusters are in Known Issues.
- `tests/server_startup_runner.tscn`: **passed** in the current checkout/cache. It loaded GameState, started the listener, emitted `GODOT_BACKEND_READY`, and passed start/next-round checks. This is not proof of clean-cache Linux behavior.
- Headless `scenes/main.tscn` smoke: **passed**, exit 0, zero error-level messages (19 warnings observed).
- The client runner and deployment instructions were inspected; a Node proxy + Godot topology smoke, two-client online smoke, web export, and clean-cache Linux test were **not run** during handoff preparation.
- No gameplay implementation was modified. `git diff --check` is required after adding this document and before commit.

### Repeatable test matrix

Run from repository root in PowerShell. Set the executable path as follows:

```powershell
$env:GODOT_BIN="C:\Users\padet_s\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"
```

The executable was also used directly for the Godot MCP headless runner checks.

| Check | Command / procedure | Scope |
|---|---|---|
| GDScript project parse/import validation | `& $env:GODOT_BIN --headless --path . --editor --quit` | Headless editor scan/import; inspect exit code and error output. Does not replace behavioral tests. |
| Full validation runner | `& $env:GODOT_BIN --headless --path . res://tests/validation_runner.tscn` | Rules, roles/exchange, match, room, bot, layout, and animation assertions. Current baseline fails as detailed below. |
| Main-scene smoke | `& $env:GODOT_BIN --headless --path . res://scenes/main.tscn --quit-after 120` | Main scene loads and runs briefly without error-level output. |
| Server startup regression | `& $env:GODOT_BIN --headless --path . res://tests/server_startup_runner.tscn` | GameState dynamic load, endpoint/RoomService startup, readiness, start/next-round. Passed in current cache. |
| Clean-cache GameState regression | Use a fresh Linux checkout/container with no copied `.godot/` cache; install/run Godot 4.7.2 export/editor binary and invoke `--headless --path <fresh-checkout> res://tests/server_startup_runner.tscn`. | Verifies server-critical scripts do not depend on editor-generated global class cache. Not run here. Do not clean/delete the working checkout's `.godot/` as part of routine handoff validation. |
| Node proxy + Godot backend topology | Build with `docker build -t slave-card-server .`; run `docker run --rm -p 10000:10000 slave-card-server`; poll `Invoke-WebRequest http://localhost:10000/health` until `proxy_alive` and `godot_backend_ready` are true. Then check a WebSocket upgrade/client connection on `/`. | Verifies container child process, internal port 10001, readiness gate, and public proxy path. Not run here. |
| Two-client multiplayer smoke | Start the server/proxy as above. In two separate terminals run `& $env:GODOT_BIN --headless --path . res://tests/network_client_runner.tscn -- wss://<host>/ host` and `& $env:GODOT_BIN --headless --path . res://tests/network_client_runner.tscn -- wss://<host>/ join <room-code>`. For a local direct Godot listener use `ws://127.0.0.1:10000/`. | Host creates a room; guest joins; both ready; host starts; checks start/deal/turn snapshots and six actions including pass. Runner defaults to 20-second timeout. Use host's printed room code for join. Not run here. |
| Web export | `$env:GODOT_BIN="C:\Users\padet_s\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"` then `python tools/export_web.py` | Rebuild committed web output. For production URL, set `$env:SLAVE_CARD_SERVER_URL="wss://slave-card-server.onrender.com"` before export. Not run here; it would modify tracked generated web artifacts. |
| Patch whitespace | `git diff --check` | Must pass before handoff commit. |

## Current Known Issues / Tech Debt

Current validation runner result is 99 assertion failures plus one runtime exception. Failure counts below are grouped from the runner output; assertion totals exclude the uncaught exception. “Production block” describes whether the failure should block shipping an affected change, not whether the existing Render deployment is currently down.

| Cluster | Current evidence | Classification | Risk / production impact |
|---|---|---|---|
| Seat/layout expectations: 77 assertions | Every local-player/count combination from 2–12 fails a combined “local South and deterministic next-player-left mapping” assertion. Additional checks fail for 2-player opponent North, 4-player South/West/North/East order, and role badge alignment. Local South itself is implemented; combined assertions do not isolate which part failed. Role badge is deliberately outside the panel in current UI. | Stale/over-broad test expectations are likely for badge placement; seat order remains unresolved and may be a real visual/layout defect. | Medium; could affect online readability/navigation. Needs focused test and visual review before changing layout. |
| Straight expectations and generation: 14 assertions | Failures include Straight-vs-Triple compatibility, 3/4-card Straight/Straight Flush acceptance/rejection and generation, four-card sequence classification, Straight render expectation, and bot response expectation. Current code permits 3–8. The user-provided locked contract says exactly five. | Mixed: implementation violates the stated exact-five contract; some tests appear stale relative to current type-lock rules. Requires product/source/test reconciliation. | High for gameplay correctness; blocks treating current rule behavior as settled. |
| Exchange test | Five assertions expect slaves to be automatically ready and exchanges to commit after upper-role picks. Current code requires human Slave confirmation. At line 498 the test then indexes a missing completed transfer and throws. | Outdated test assumptions plus a test robustness bug; whether UX contract intentionally requires both sides' confirmation should be verified against current product requirement. | Medium; exchange flow is production gameplay. Test suite is not a reliable gate until updated. |
| Main smoke warnings | Main scene returned exit 0 with no error-level messages and 19 warnings. | Warnings were not individually audited for impact. | Low/unknown; inspect if they recur as errors or asset failures. |
| Clean Linux/cold-cache + full online topology | Not run in this handoff. Current startup runner only proves current checkout/cache startup. | Unverified operational risk, not a confirmed bug. | Medium for production deploy confidence. |

The 99 assertions group as 77 combined seat-order/layout checks, 14 Straight-related checks, 5 exchange checks, and 3 additional layout checks (two seat-position cases and one role-badge placement check). The separate uncaught exchange exception is not included in the assertion total. **Do not treat the seat cluster as proof that local-South placement itself fails:** that assertion combines South placement with turn-order mapping.

## File Map

| File | Responsibility |
|---|---|
| `scripts/network/network_protocol.gd` | Protocol message constants and message payload wrapper. |
| `scripts/network/network_endpoint.gd` | Reliable RPC base, sender validation, message processing contract. |
| `scripts/network/client_network_endpoint.gd` | Client WebSocket connection and client-side endpoint signals. |
| `scripts/network/server_network_endpoint.gd` | Server WebSocket listener, environment-configured bind/port, readiness signal. |
| `scripts/network/room_service.gd` | Authoritative rooms, lobby, match flow, snapshots, bots, leave/disconnect handling. |
| `scripts/ui/multiplayer_flow.gd` | Online lobby, exchange, RPS, gameplay views and client intent handling. |
| `scripts/ui/game_ui.gd` | Local game UI, bots, local RPS/exchange and round presentation. |
| `scripts/ui/table_layout.gd` | Reference-resolution HUD/table geometry. |
| `scripts/ui/table_presentation.gd` | Seats, panels, role badges, center pile and play animation. |
| `scripts/ui/card_view.gd` | Reusable card display, hover/selection and multi-card animation layout. |
| `scripts/game/game_rules.gd` | Combination classification, ranking, legal generation and parity/type response rules. |
| `scripts/game/game_state.gd` | Turn, trick, pass, play validation and round state. |
| `scripts/game/game_state_factory.gd` | Explicit dynamic construction/loading path for GameState. |
| `scripts/game/match_state.gd` | Match round limits, points, history and ranking/tiebreak order. |
| `scripts/game/card_exchange.gd` | Role-based exchange amounts, mandatory slave cards, readiness and transfer commit. |
| `scripts/game/role_system.gd` | Finish-position to role mapping and demotion/promotion. |
| `scripts/cards/card_data.gd` | Card identity, rank/suit strength and serialization. |
| `scripts/cards/deck_factory.gd` | Deck count/dealing source. |
| `scripts/game/bot_brain.gd` | Bot legal-play selection. |
| `scripts/audio/sfx_manager.gd` | Lazy client SFX with headless/dedicated-server safety. |
| `server/render_proxy.js` | Public HTTP/WebSocket proxy, child Godot lifecycle and readiness health endpoint. |
| `Dockerfile` | Node 22 + Godot 4.7.2 server container. |
| `render.yaml` | Render server/static site definitions and health path. |
| `DEPLOYMENT.md` | Local, Render, Web export and static publishing instructions. |
| `tools/export_web.py` | Godot Web export, optional production WebSocket URL injection and config restoration. |
| `tests/validation_runner.gd` / `.tscn` | Broad rules, state, lobby, match, bot, UI/layout validation. |
| `tests/server_startup_runner.gd` / `.tscn` | Server GameState load, listener readiness and round start regression. |
| `tests/network_client_runner.gd` / `.tscn` | Host/join WebSocket integration client for two-client proxy smoke. |
| `web-build/` | Tracked production Web export; includes critical `index.html` and `index.pck`. |

## DO NOT REGRESS

- Keep the server authoritative for rooms, player state, rules, turns, bots, exchange, and match progression.
- Production serves committed `web-build/`; refresh and commit the complete Web export, including `index.pck`, for client changes.
- Keep local player seated South.
- Preserve odd/even family restrictions and do not redesign Pair logic casually.
- Product contract: Straight is exactly 5 cards; Straight Flush is exactly 5 cards. Current implementation conflicts with this and needs explicit reconciliation before changing rules.
- Keep headless/dedicated server independent from MP3/audio import and eager audio loading.
- Keep GameState clean-cache loading valid; do not rely on editor-generated `.godot` global class cache.
- Health/readiness must represent Godot backend readiness; no raw periodic fake WebSocket probes.
- Lobby leave/disconnect must not leave ghost players. Host leave closes the lobby room unless product behavior has explicitly changed.
- Keep active-match disconnect/forfeit separate from lobby leave.
- Keep the previous pile visible while cards animate into the new play.
- Use the same landing layout for multi-card flight and final pile.
- Duplicate deck identity must not make otherwise identical cards stronger.
- Preserve server-controlled host authority for start, next-round, and continue/rematch actions.

## Open Questions for Hoshi

- How should exact-five Straight/Straight Flush contract be reconciled with current 3–8 implementation and legacy validation assertions?
- Which seat-order assertions represent stale layout expectations, and which indicate a real seating defect? The current combined test does not isolate local-South from clockwise order.
- Should the role badge test be updated to the current sibling/right-of-panel placement?
- Should exchange tests be updated to require human Slave confirmation, or does the product requirement expect a different readiness flow?
- Can the broad validation runner be made robust so an incomplete exchange cannot abort its own test section?
- Are any production-only Linux/cold-cache risks still present after a clean checkout test?
- Does current gameplay need broader visual QA at 9–12 players? The repository supports those counts, but handoff checks did not visually exercise all layouts.
- What is the canonical public URL for the Render Static Site? It is not explicitly recorded in repository configuration.
- Can the Start Game lambda-capture incident be located in older Git history or issue records? It was not verified from the inspected commits.

## Hoshi Routing Instruction

Hoshi should review this handoff, inspect the current repository state, and independently decide whether each next work item should be assigned to Yuki, Mizuki, or Bell. Do not pre-assign downstream ownership in this handoff.

Hoshi may split work across multiple owners, request more evidence, reject stale issues, or reorder priorities. This handoff makes no routing decision.
