# TriCaster + BirdDog plan

Goal: run Churchfront Video against a NewTek/Vizrt TriCaster Mini 4K and two BirdDog
EYES P400 cameras instead of an ATEM and Canon cameras, keeping the operator UI,
camera tracking and the Claude tools.

## The gear (read-only probe, 2026-11-18)

| Device | Address | Talks |
| --- | --- | --- |
| TriCaster Mini 4K, software 8-4, 2160p29.97 | 192.168.254.15 | HTTP API on 5952 (no login), WebSocket change notifications, LivePanel Web on 80 |
| BirdDog P400 "MAIN CAM", fw 5.5.116 | 192.168.254.16 | VISCA over IP (UDP 52381) answers; REST on 8080; NDI |
| BirdDog P400 "2ND CAM", fw 5.5.116 | 192.168.254.17 | same |

TriCaster inputs: 1 MAIN CAM, 2 2ND CAM, 3 STAGE CAM, 4 Pro Main, 5 Pro7 Lower 3rd,
6 Pro7 Stage, 7–8 unused. Also DDR 1–4, GFX 1–2, buffers bfr1–15, M/E 1–4 (v1–v4),
DSK 1–4 on Main, 4 mix outputs.

## TriCaster API, as seen on this unit

- `GET /v1/version`: product, version, session name and format.
- `GET /v1/dictionary?key=shortcut_states`: every state value (~370 KB, ~16 ms).
- `GET /v1/dictionary?key=tally`: per source `on_pgm` / `on_prev` (~3 KB).
- `GET /v1/dictionary?key=macros_list`: macro folders, names and ids.
- `ws://…:5952/v1/change_notifications`: pushes which dictionary changed.
- `GET /v1/shortcut?name=<shortcut>&value=<v>`: every command.

Keys the app needs (from `shortcut_states`):

| App concept | TriCaster key |
| --- | --- |
| Input names | `inputN_long_name` |
| Main program / preview | `main_a_row_named_input` / `main_b_row_named_input` (A = program: **verify**) |
| Cut / Auto / T-bar | `main_take`, `main_auto`, `main_value` |
| Next transition (ATEM "next selection") | `main_delegate` (e.g. `main_background\|main_dsk1`) |
| DSK 1–4 on air, auto, source | `main_dskN_take` / `_auto` / `_value` / `_select_named_input` |
| Fade to black | `main_ftb_take` / `main_ftb_auto` |
| M/E 1–4 | `vN_a_row_named_input`, `vN_b_row_named_input`, `vN_take`, `vN_auto`, `vN_value` |
| Aux outputs | `mixN_output_source` (mix 1–4) |
| Macros | `macros_list` + play by id/name |
| Record / stream | `record_toggle`, stream key **to find** |
| Tally | `tally` dictionary |

## How it fits the code

The UI reaches the switcher through one `ATEMClient` environment object (about 25
commands plus `ATEMState`). Plan: keep that seam and keep the diff to `ATEM.swift` tiny,
so upstream changes still merge.

1. **Switcher seam.** Make `ATEMClient` subclassable (`open`, state settable inside
   `CueATEM`). Add `switcher: "atem" | "tricaster"` to config, auto-detected
   (`/v1/version` on 5952 → TriCaster, UDP 9910 hello → ATEM). The app creates the
   matching client and hands it to the views as `ATEMClient`.
2. **`TriCasterClient`** (`Sources/CueATEM/TriCaster.swift`):
   - Connect: version → full state + tally → WebSocket. On a notification, refetch that
     dictionary; if the socket drops, poll tally and state and reconnect.
   - Map sources to stable ids that fit `ATEMInput`'s helpers (inputs 1–8 keep 1–8;
     DDR, GFX, buffers, Black, M/E outputs get fixed ids) so saved config and routes hold.
   - M/E 0 = Main, M/E 1–4 = TriCaster M/E 1–4. DSK 1–4 map to ATEM DSKs; "next
     transition" maps to `main_delegate`.
   - Log every shortcut sent in the Status page.
   - Hide what the TriCaster has no match for (ATEM DSK tie, wipe styles) rather than fake it.
3. **Cameras.** Add both P400s as VISCA (UDP 52381) on TriCaster inputs 1 and 2. `main`
   already does VISCA shots, exposure and NDI-picture tracking, so this is mostly setup
   plus BirdDog quirks (speed ranges, focus, preset numbering). Pictures come from each
   camera's own NDI stream.
4. **Monitors.** Use the TriCaster's NDI Program and Preview outputs for the Live and Next
   monitors (in place of the ATEM multiview).
5. **Finding devices / Claude.** `find_devices` also finds TriCasters (5952) and BirdDog
   cameras (8080 `/about`). MCP tools work unchanged through the client.
6. **Testing.** `Tools/fake_tricaster.py` (HTTP + WebSocket, seeded from a captured
   state with serials removed) for the self-test, and parsing tests in `swift test`.
7. **Real hardware**, off-service with someone watching: read-only probe first, then a
   real test that sends each command once and puts everything back (as was done on the
   ATEM, see HANDOFF.md).

## Status (2026-11-18)

Working on the real TriCaster: `ATEMClient.connect` finds it on port 5952 by itself, so
`atemHost` is just its address. `CUEVIDEO_REALTEST=1` passes 18 of 18 (preview, cut, auto,
T-bar, DSK tie and auto, M/E key, mix output) and puts everything back.

Learned on the unit:
- Main program/preview come from the `switcher` dictionary (`main_source`, `preview_source`);
  `shortcut_states` lags about two seconds, so it's only used for settings.
- The WebSocket names the dictionary that changed (with a trailing NUL) at the start and end
  of a transition, not during it.
- `main_value` (T-bar) takes 0 to 100.
- No shortcut found sets transition speed (`main_speed`, `main_background_speed` with 0.5, 1,
  2 and 2.5 do nothing), and `main_background_select_fade` resets the speed to Medium. The app
  shows the TriCaster's speed and style but doesn't change them.
- `play_macro_byid` and `play_macro_byname` answer "Shortcut executed" but didn't run the
  built-in "Transition Speed: Slow" macro. Running macros is not confirmed yet.
- Every shortcut answers "Shortcut executed", even unknown ones, so a command only counts as
  working when the state changes.
- Building on this Mac (Command Line Tools, no Xcode): SwiftUI's macro plugin isn't in the
  tools, so build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

## Open questions

- How to run a macro over the API (many macros are camera shots, such as "Main Josh Preaching").
- Fade to black: `main_ftb_auto` is untested and its state isn't reported.
- Streaming and recording: `streaming_toggle` / `record_toggle` untested (never while live).
