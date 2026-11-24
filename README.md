# AMX Mod X - Webhook Reporter

CS 1.6 AMX Mod X plugin that forwards server events to a Discord webhook. Uses [AmxxEasyHttp](https://github.com/Next21Team/AmxxEasyHttp) for HTTPS.

## Features

- **Plugin loaded / Server startup** - plain text `Server started on map ...` (map name backticked) on `plugin_cfg` first load
- **Plugin unloaded / Server shutdown** - plain text `Server shutting down (last map: ...)` (map name backticked) in `plugin_end` when not a map change
- **Map change** - embed with `Previous -> New` map name (blue, `0x3498DB`). Also sends a `Map Ended` embed (grey, `0x95A5A6`) from `plugin_end` when a map finishes
- **Player connected** - plain text, non-bot only, nickname only (filtered via `is_user_bot` / `is_user_hltv`), includes real-player count e.g. `Nick connected (3 online)`
- **Player disconnected** - plain text, non-bot only, nickname only, includes remaining real-player count e.g. `Nick disconnected (2 online)`
- **Player chat** - plain text for `say` and `say_team` with prefixes: `(A)` for Attackers (T), `(D)` for Defenders (CT), `(SPEC)` for spectators, `*DEAD*` when dead, `[TEAM]` for team chat; `(SPEC)` is also used for unassigned players. Strips color codes `^0-^9`/`!g`/`!y`/`!t`, collapses double spaces, and ignores chat commands starting with `/ ! . ? @`
- **Round finished** - embed `Attackers Win! / Defenders Win! / Round Draw! Score (A/D): T/CT` with color (red `0xE74C3C` for Attackers, blue `0x3498DB` for Defenders, grey `0x95A5A6` for draw) and tracked via `TeamScore` message
- **Halftime (PugMod)** - embed `Halftime — Teams are switching sides... / Overtime begins...` (orange `0xE67E22`) when [SmileYzn/PugMod](https://github.com/SmileYzn/PugMod) executes halftime, detected from its `pug_state` cvar (fallback: round counting via `pug_rounds` / `pug_rounds_ot` when `pug_state` is unavailable); after a real side swap the cumulative Attackers/Defenders win counts follow the teams to their new slots, so round embeds keep showing correct match score in regulation and overtime
- **Match restarted / cancelled (PugMod)** - embeds (yellow `0xF1C40F` / grey `0x95A5A6`) carrying the score at the moment of the event, detected from `pug_state` transitions (`First Half` while a match is in progress, `Deathmatch` / `Dead` while a match is in progress); cumulative score and halftime state reset, queued round/halftime embeds dropped

No `@mentions`, no SteamID/IP/hostname broadcasting.

## Requirements

- AMX Mod X 1.9+ recommended (1.8.3 partially supported - 32-char native limit)
- `AmxxEasyHttp` 1.4.0+ module (`easy_http_amxx_i386.so` / `easy_http_amxx.dll`)
- Discord webhook URL

## Installation

1. **Discord webhook**

   - Discord -> Server Settings -> Integrations -> Webhooks -> New Webhook
   - Choose channel, copy **Webhook URL** (`https://discord.com/api/webhooks/...`)

2. **AmxxEasyHttp module**

   ```
   cstrike/addons/amxmodx/modules/easy_http_amxx_i386.so   (Linux)
   cstrike/addons/amxmodx/modules/easy_http_amxx.dll       (Windows)
   ```
   Add to `cstrike/addons/amxmodx/configs/modules.ini`:
   ```
   easy_http
   ```
   Verify: `amxx modules` in server console shows `easy_http` as `running`.

3. **Plugin**

   Copy to server (paths are relative to `cstrike/`):
   ```
   amxmodx/scripting/webhook_reporter.sma          -> (source, optional)
   amxmodx/scripting/compiled/webhook_reporter.amxx -> cstrike/addons/amxmodx/plugins/webhook_reporter.amxx
   amxmodx/configs/webhook_reporter.cfg             -> cstrike/addons/amxmodx/configs/webhook_reporter.cfg
   ```
   Add to `cstrike/addons/amxmodx/configs/plugins.ini`:
   ```
   webhook_reporter.amxx
   ```

4. **Configure webhook**

   Edit `cstrike/addons/amxmodx/configs/webhook_reporter.cfg`:
   ```cfg
   amx_webhook_url "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"
   amx_webhook_botname "CS 1.6 Server"
   ```
   The file is `exec`'d automatically in `plugin_cfg`. You can also set the cvar via `server.cfg` or RCON:
   ```
   amx_webhook_url "https://discord.com/api/webhooks/..."
   ```

5. Restart / `amx_reloadadmins` / `changelevel`:

   ```
   amxx plugins   // should show webhook_reporter as running
   amxx cvars     // amx_webhook_url should be set
   ```

## Configuration

| CVar                  | Default         | Description                                                              |
|-----------------------|-----------------|--------------------------------------------------------------------------|
| `amx_webhook_url`     | `""`            | **Required.** Single Discord webhook URL. Keep private (protected flag). |
| `amx_webhook_botname` | `CS 1.6 Server` | Username shown in Discord messages                                       |

All messages are queued via `EzHttpQueue` and sent with `Content-Type: application/json`. Requests that would be interrupted by map change use `EZH_FORGET_REQUEST` (fire-and-forget) so the `Map Ended` webhook still fires.

`bForget` (`bool:bForget` in `Webhook_PostPlain`/`Webhook_SendEmbedRaw`) maps to `EzHttpPluginEndBehaviour` (`easy_http.inc`): `false` = `EZH_CANCEL_REQUEST` (default, callback receives `EZH_REQUEST_CANCELLED` on map change), `true` = `EZH_FORGET_REQUEST` (request completes after `ServerDeactivate` but callback is not invoked). The plugin passes `true` only in `plugin_end` so shutdown/map-ended webhooks are not lost.

`log_amx` writes to `cstrike/addons/amxmodx/logs/L<YYYYMMDD>.log` (daily log) and mirrors to console. Check `addons/amxmodx/logs/` for `[Webhook] amx_webhook_url not set` or `[Webhook] POST failed err=...`.

## Message Format

- **Plain** (`content`): startup, shutdown, connects, disconnects, chat. Example:
  ```
  (A) PlayerName: hello team
  *DEAD* (D) [TEAM] PlayerName: nice try
  PlayerName connected (5 online)
  PlayerName disconnected (4 online)
  Server started on map `de_dust2`
  Server shutting down (last map: `de_dust2`)
  ```
- **Embed**: map change, round win, and map ended. Example round embed:
  ```
  Title: Round Finished
  Description: Attackers Win! Score (A/D): 7/5
  Color: 0xE74C3C
  ```
  Example map change / map ended embeds:
  ```
  Title: Map Change
  Description: `de_dust2` -> `cs_office`
  Color: 0x3498DB

  Title: Map Ended
  Description: `de_dust2`
  Color: 0x95A5A6
  ```
  Example halftime embeds (PugMod):
  ```
  Title: Halftime
  Description: Teams are switching sides. First half score (A/D): 8/7
  Color: 0xE67E22

  Title: Halftime
  Description: Halftime — teams keep their sides. Overtime begins. Score (A/D): 15/15
  Color: 0xE67E22

  Title: Match Restarted
  Description: A new match will start shortly. Score was (A/D): 6/4
  Color: 0xF1C40F

  Title: Match Cancelled
  Description: The match was cancelled. Final score (A/D): 6/4
  Color: 0x95A5A6
  ```

## Compilation

### GitHub Actions

Push to `main`/`master` triggers `.github/workflows/build.yml`:

- Installs AMX Mod X 1.10 compiler
- Fetches `easy_http.inc` / `easy_http_json.inc` from `Next21Team/AmxxEasyHttp`
- Compiles `amxmodx/scripting/webhook_reporter.sma` -> `amxmodx/scripting/compiled/webhook_reporter.amxx`
- Uploads artifact `webhook_reporter.amxx`

Download the artifact from the Actions tab.

### Local

With `amxxpc` and EasyHttp includes in `include/`:

```bash
amxxpc amxmodx/scripting/webhook_reporter.sma \
  -oamxmodx/scripting/compiled/webhook_reporter.amxx \
  -iamxmodx/scripting/include
```

Or use AMXX Studio / VS Code Pawn extension.

## Folder Layout (to copy to server)

```
amxmodx/
  scripting/
    webhook_reporter.sma
    compiled/
      webhook_reporter.amxx   # built artifact, gitignored
  configs/
    webhook_reporter.cfg
    webhook_reporter.cfg.example
```

No Gold Discord library, no extra dependencies other than AMXX Easy HTTP.

## Troubleshooting

- **`amx_webhook_url not set — dropping`** in `cstrike/addons/amxmodx/logs/L<YYYYMMDD>.log` (also `error_*.log`, `amxx logs`) - `log_amx` always writes there - `amx_webhook_url` empty; check `webhook_reporter.cfg` and `amxx cvars`.
- **`easy_http` not running** -> module not in `modules.ini` or wrong binary (Linux vs Windows), check `amxx modules` and `meta list` if using Metamod.
- **No Discord message** -> test webhook with `curl -H "Content-Type: application/json" -d '{"content":"test"}' https://discord.com/api/webhooks/...` ; check server can reach `discord.com:443` (firewall).
- **HTTP error logged** (`[Webhook] POST failed err=... http=...` in same `L*.log`) -> see `EzHttpErrorCode` in `easy_http.inc` (`EZH_HOST_RESOLUTION_FAILURE`, `EZH_SSL_*`); check SSL deps on host.
- **Map Ended not firing** -> `plugin_end` uses `bForget=true` -> `EZH_FORGET_REQUEST`; if you see `EZH_REQUEST_CANCELLED`, update EasyHttp to 1.4.0+.
- **Bots still logged** -> ensure `is_user_bot`/`is_user_hltv` checks; PODBot etc. are correctly flagged.
- **Player chat appears twice in-game** -> older builds hooked `SayText` for PugMod detection, which made AMXX intercept and re-emit every game chat line. Current builds read `pug_state` instead and never hook `SayText`; make sure the current `webhook_reporter.amxx` is installed and that no other chat/prefix plugin is reprinting `say` messages.

## Internals

- Scores: `g_iTScore` / `g_iCTScore` updated from `TeamScore` message (`register_message`), used in round-win embeds. Under PugMod (auto-detected), round-win embeds instead use cumulative `g_iTotalT` / `g_iTotalCT`.
- PugMod detection: PugMod exposes `pug_state` (`CPugMod::SetState` writes the numeric state on every transition). The plugin polls it every 0.25 s instead of hooking `SayText`; hooking `SayText` makes AMXX swallow/re-emit every game chat line, which duplicated player chat in-game. State values: `0` Dead, `1` Deathmatch, `2` Vote Map, `3` Vote Team, `4` Captains, `5` Knife Round, `6` First Half, `7` Halftime, `8` Second Half, `9` Overtime, `10` Finished.
- PugMod scores: at halftime the mod resets team slots to `0/0` (`m_bCompleteReset` + `SwapAllPlayers`, which itself swaps then zeroes slot wins) and with `pug_score_teams 1` rewrites outgoing `TeamScore` args - the plugin's own totals (`g_iTotalT` / `g_iTotalCT`) avoid depending on meta message-hook ordering. Winner attribution stays slot-based (`SendAudio` terwin/ctwin always describe the current T/CT slot); the halftime **swap of the cumulative totals** (not inverted increments) keeps them following the player group, matching the TAB scoreboard. The swap condition mirrors `CPugMod::SwapTeams`: a tied score at the end of regulation keeps the sides (overtime), otherwise the totals are exchanged.
- PugMod live gating: `pug_state` First Half / Second Half / Overtime are the only scoring states, so knife rounds, voting freezes and DM mode are excluded. The state is read at `SendAudio` time, so a knife-round win cannot slip through between poll ticks.
- PugMod restart/cancel: a transition to First Half while a match is in progress emits `Match Restarted`; a transition to Deathmatch / Dead while a match is in progress emits `Match Cancelled`. Finished (`10`) marks the match as ended and suppresses the post-match Deathmatch / Vote Map transitions, so a normal match end is not reported as a restart or cancel. Scores, halftime counters and pending `TASK_ROUND`/`TASK_HALFTIME` embeds are dropped immediately on restart/cancel.
- PugMod fallback (older PugMod without `pug_state`, or another halftime system with the same cvars): halftime is inferred after `pug_rounds / 2` round wins per regulation half and `pug_rounds_ot / 2` per overtime half (halftime #3+ = OT). Limitations: it assumes a swap at every halftime, counts knife-round wins (so the knife-round feature can shift it by one round), and cannot detect restart/cancel at all.
- All PugMod/halftime state resets in `plugin_cfg` (`Task_ReadCvarsAndHandle`), including mid-map plugin loads; `Pug_ReadConfig` reads `pug_state` / `pug_rounds` / `pug_rounds_ot` via `get_cvar_pointer` each map and (re)starts the poll task.
- Map vs shutdown: `g_bChangingMap` set by `server_changelevel()` and `changelevel`/`map`/`amx_map` command hooks; `plugin_end` sends `Map Ended` embed if true else `Server shutting down` plain.
- Hungarian notation: `g_i*`, `g_sz*`, `g_b*`, `g_p*`, `g_Queue`.

## Uninstall

Remove `webhook_reporter.amxx` from `plugins.ini` and delete `webhook_reporter.cfg` / module if unused.
