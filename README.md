# AMX Mod X - Webhook Reporter

CS 1.6 AMX Mod X plugin that forwards server events to a Discord webhook. Uses [AmxxEasyHttp](https://github.com/Next21Team/AmxxEasyHttp) for HTTPS.

## Features

- **Plugin loaded / Server startup** - plain text on `plugin_cfg` first load
- **Plugin unloaded / Server shutdown** - plain text in `plugin_end` when not a map change
- **Map change** - embed with `Previous -> New` map name (blue, `0x3498DB`). Also sends a `Map Ended` embed from `plugin_end` when a map finishes
- **Player connected** - plain text, non-bot only, nickname only (filtered via `is_user_bot` / `is_user_hltv`)
- **Player disconnected** - plain text, non-bot only, nickname only
- **Player chat** - plain text for `say` and `say_team` with prefixes: `(A)` for Attackers (T), `(D)` for Defenders (CT), `(SPEC)` for spectators, `*DEAD*` when dead, `[TEAM]` for team chat. Strips color codes `^1-^4`/`!g`/`!y`/`!t` and ignores chat commands starting with `/ ! . ? @`
- **Round finished** - embed `Attackers Win! / Defenders Win! / Round Draw! Score (A/D): T/CT` with color (red `0xE74C3C` for Attackers, blue `0x3498DB` for Defenders, grey `0x95A5A6` for draw) and tracked via `TeamScore` message

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

`bForget` (`bool:bForget` in `Webhook_PostPlain`/`Webhook_SendEmbedRaw:45`) maps to `EzHttpPluginEndBehaviour` (`easy_http.inc:60`): `false` = `EZH_CANCEL_REQUEST` (default, callback receives `EZH_REQUEST_CANCELLED` on map change), `true` = `EZH_FORGET_REQUEST` (request completes after `ServerDeactivate` but callback is not invoked). The plugin passes `true` only in `plugin_end:43` so shutdown/map-ended webhooks are not lost.

`log_amx` writes to `cstrike/addons/amxmodx/logs/L<YYYYMMDD>.log` (daily log) and mirrors to console. Check `addons/amxmodx/logs/` for `[Webhook] amx_webhook_url not set` or `[Webhook] POST failed err=...`.

## Message Format

- **Plain** (`content`): startup, shutdown, connects, disconnects, chat. Example:
  ```
  (A) PlayerName: hello team
  *DEAD* (D) [TEAM] PlayerName: nice try
  PlayerName connected
  PlayerName disconnected
  Plugin loaded - Server started on map `de_dust2`
  Plugin unloaded - Server shutting down (last map: de_dust2)
  ```
- **Embed**: map change and round win. Example round embed:
  ```
  Title: Round Finished
  Description: Attackers Win! Score (A/D): 7/5
  Color: 0xE74C3C
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

- **`amx_webhook_url not set - dropping`** in `cstrike/addons/amxmodx/logs/L<YYYYMMDD>.log` (also `error_*.log`, `amxx logs`) - `log_amx` always writes there - `amx_webhook_url` empty; check `webhook_reporter.cfg` and `amxx cvars`.
- **`easy_http` not running** -> module not in `modules.ini` or wrong binary (Linux vs Windows), check `amxx modules` and `meta list` if using Metamod.
- **No Discord message** -> test webhook with `curl -H "Content-Type: application/json" -d '{"content":"test"}' https://discord.com/api/webhooks/...` ; check server can reach `discord.com:443` (firewall).
- **HTTP error logged** (`[Webhook] POST failed err=... http=...` in same `L*.log`) -> see `EzHttpErrorCode` in `easy_http.inc` (`EZH_HOST_RESOLUTION_FAILURE`, `EZH_SSL_*`); check SSL deps on host.
- **Map Ended not firing** -> `plugin_end` uses `bForget=true` -> `EZH_FORGET_REQUEST`; if you see `EZH_REQUEST_CANCELLED`, update EasyHttp to 1.4.0+.
- **Bots still logged** -> ensure `is_user_bot`/`is_user_hltv` checks; PODBot etc. are correctly flagged.

## Internals

- Scores: `g_iTScore` / `g_iCTScore` updated from `TeamScore` message (`register_message`), used in round-win embeds.
- Map vs shutdown: `g_bChangingMap` set by `server_changelevel()` and `changelevel`/`map`/`amx_map` command hooks; `plugin_end` sends `Map Ended` embed if true else `Server shutting down` plain.
- Hungarian notation: `g_i*`, `g_sz*`, `g_b*`, `g_p*`, `g_Queue`.

## Uninstall

Remove `webhook_reporter.amxx` from `plugins.ini` and delete `webhook_reporter.cfg` / module if unused.
