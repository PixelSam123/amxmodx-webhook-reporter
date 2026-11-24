// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 PixelSam123

#pragma semicolon 1

#include <amxmodx>
#include <cstrike>
#include <easy_http>
#include <easy_http_json>

#define PLUGIN "Discord Webhook Reporter"
#define VERSION "1.2.1"
#define AUTHOR "PixelSam123"

#define MAX_WEBHOOK_URL 512
#define MAX_MSG_LEN     512
#define MAX_CHAT_LEN    384

// Task ids: never use raw player ids as task ids (collides with cfg task id 0).
// Use a dedicated base offset per task type.
#define TASK_CFG          9876
#define TASK_ROUND        9877
#define TASK_HALFTIME     9878
#define TASK_PUG_POLL     9879
#define TASK_SEND_QUEUE   9880
#define TASK_CONNECT_BASE 5000

// Outbound rate limiting. Discord's webhook route is roughly 30 requests per
// minute; allow a small burst, then pace the rest. amx_webhook_rate_limit is
// the seconds between requests once the burst is spent (0 disables pacing).
#define SEND_QUEUE_TICK   0.1
#define RATE_CAPACITY     5.0
#define MAX_PENDING       100
#define MAX_RETRIES       2
#define MAX_BODY_LEN      1536

#define COLOR_HALFTIME    0xE67E22
#define COLOR_RESTART     0xF1C40F
#define COLOR_CANCEL      0x95A5A6

// CPugMod::SetState values exposed through the `pug_state` cvar (PugMod.h).
#define PUG_STATE_DEAD        0
#define PUG_STATE_DEATHMATCH  1
#define PUG_STATE_VOTEMAP     2
#define PUG_STATE_VOTETEAM    3
#define PUG_STATE_CAPTAIN     4
#define PUG_STATE_KNIFE       5
#define PUG_STATE_FIRST_HALF  6
#define PUG_STATE_HALFTIME    7
#define PUG_STATE_SECOND_HALF 8
#define PUG_STATE_OVERTIME    9
#define PUG_STATE_END         10

new g_pCvarWebhookUrl;
new g_pCvarBotName;
new g_pCvarRateLimit;

new g_szPrevMap[64];
new bool:g_bFirstCfg = true;
new bool:g_bChangingMap = false;

new g_iTScore;
new g_iCTScore;
new bool:g_bPendingTWin;
new bool:g_bPendingDraw;

new EzHttpQueue:g_Queue;

// Outbound sender: one request in flight, burst bucket + 429 backoff.
new Array:g_Pending;
new bool:g_bSenderReady;
new bool:g_bSending;
new bool:g_bQueueFullLogged;
new Float:g_flTokens = RATE_CAPACITY;
new Float:g_flTokenTime;
new Float:g_flNextSend;
new EzHttpRequest:g_CurrentRequest;
new g_szCurrentBody[MAX_BODY_LEN];
new g_iCurrentRetries;

new g_iMsgTeamScore;

// PugMod (SmileYzn/PugMod) match-state tracking.
// g_bPugStateMode: PugMod is present and exposes `pug_state` (updated by
// CPugMod::SetState on every transition). State is read from that cvar instead
// of hooking SayText: hooking SayText makes AMXX swallow/re-emit every game
// chat line, which duplicated player chat in-game.
// g_bPugMode: use plugin-side cumulative totals instead of TeamScore messages
// (PugMod zeroes team slots at halftime via m_bCompleteReset and rewrites the
// TeamScore message args when pug_score_teams=1, so the raw message is not a
// reliable score source). Cumulative totals live in g_iTotalT/g_iTotalCT.
// g_bPugFallback: older PugMod without `pug_state`; infer halftime from rounds.
new bool:g_bPugMode;
new bool:g_bPugFallback;
new bool:g_bPugStateMode;
new g_pCvarPugState;
new g_iPugState;
new g_iPugRounds = 30;
new g_iTotalT;
new g_iTotalCT;
new g_iPugRegHalf;
new g_iPugOTHalf;
new g_iPugHalfRounds;
new g_iPugHalfTimes;
new bool:g_bHalftimePending;
new bool:g_bHalftimeSwap;
new g_iHalftimeScoreT;
new g_iHalftimeScoreD;
// A match finished normally (pug_state END). Suppresses the restart/cancel
// embeds during the post-match transitions (END -> Vote Map/Deathmatch -> next
// match) until a new First Half starts.
new bool:g_bPugEnded;

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);

    g_pCvarWebhookUrl = register_cvar("amx_webhook_url", "", FCVAR_PROTECTED);
    g_pCvarBotName    = register_cvar("amx_webhook_botname", "CS 1.6 Server");
    g_pCvarRateLimit  = register_cvar("amx_webhook_rate_limit", "2.5");

    g_Queue = ezhttp_create_queue();
    Webhook_EnsureSender();
    g_iMsgTeamScore = get_user_msgid("TeamScore");

    register_clcmd("say", "OnChat");
    register_clcmd("say_team", "OnChat");

    register_event("SendAudio", "OnTWin", "a", "2&%!MRAD_terwin");
    register_event("SendAudio", "OnCTWin", "a", "2&%!MRAD_ctwin");
    register_event("SendAudio", "OnRoundDraw", "a", "2&%!MRAD_rounddraw");

    // TeamScore updates after each round; also used for generic score tracking
    if (g_iMsgTeamScore > 0)
    {
        register_message(g_iMsgTeamScore, "OnTeamScore");
    }

    // Hooks for map change detection (server_changelevel forward is only engine pfnChangeLevel)
    register_concmd("changelevel", "OnMapCmd");
    register_concmd("map", "OnMapCmd");
    register_concmd("amx_map", "OnMapCmd");
    register_concmd("amx_changelevel", "OnMapCmd");

    // Fallback logevent for round draw via log as well
    // get initial scores to 0
    g_iTScore = 0;
    g_iCTScore = 0;
    get_mapname(g_szPrevMap, charsmax(g_szPrevMap));
}

public plugin_cfg()
{
    // Single delayed path: exec config then read cvars + handle map logic in one task.
    // server_cmd is queued, so we must wait for exec to complete before reading.
    server_cmd("exec addons/amxmodx/configs/webhook_reporter.cfg");
    remove_task(TASK_CFG);
    set_task(0.5, "Task_ReadCvarsAndHandle", TASK_CFG);
}

public Task_ReadCvarsAndHandle(iTaskId)
{
    // iTaskId == TASK_CFG, unused except to satisfy set_task callback signature.
    #pragma unused iTaskId

    // (Re)start the outbound sender after a map change / reload.
    Webhook_EnsureSender();

    new szNextMap[64];
    get_mapname(szNextMap, charsmax(szNextMap));

    if (g_bFirstCfg)
    {
        g_bFirstCfg = false;
        copy(g_szPrevMap, charsmax(g_szPrevMap), szNextMap);
        Webhook_SendPlain("Server started on map `%s`", szNextMap);
    }
    else
    {
        // Map change detection: plugin_cfg of new map
        if (!equal(g_szPrevMap, szNextMap))
        {
            Webhook_SendMapChangeEmbed(g_szPrevMap, szNextMap);
            copy(g_szPrevMap, charsmax(g_szPrevMap), szNextMap);
        }
        // Reset map change flag after handling
        g_bChangingMap = false;
    }

    // Reset score/round tracking. Done on every plugin_cfg (including a mid-map
    // load) so PugMod detection + per-half state always starts clean.
    // Scores reset on new map (engine resets, but we also reset for safety)
    g_iTScore = 0;
    g_iCTScore = 0;
    g_iTotalT = 0;
    g_iTotalCT = 0;
    g_iPugHalfRounds = 0;
    g_iPugHalfTimes = 0;
    g_bPugEnded = false;
    g_bPendingTWin = false;
    g_bPendingDraw = false;
    g_bHalftimePending = false;
    g_bHalftimeSwap = false;
    // Drop any pending round/halftime embed from the previous map so it
    // doesn't fire with reset scores on the new map. Pug_ReadConfig() also
    // restarts the pug_state poll task.
    remove_task(TASK_ROUND);
    remove_task(TASK_HALFTIME);
    Pug_ReadConfig();
}

public server_changelevel(szMap[])
{
    // Engine-level map change (engine_changelevel). Mark as changing map for plugin_end differentiation
    #pragma unused szMap
    g_bChangingMap = true;
}

public OnMapCmd(id, level, cid)
{
    // changelevel/map are server-console commands; amx_map/amx_changelevel
    // require ADMIN_MAP. Do not flag a denied attempt as a map change.
    #pragma unused level, cid
    if (id == 0 || (get_user_flags(id) & ADMIN_MAP))
    {
        g_bChangingMap = true;
    }
    return PLUGIN_CONTINUE;
}

public plugin_end()
{
    // plugin_end is called on map change AND on server shutdown/unload.
    // g_bChangingMap distinguishes the two (best-effort; covers changelevel/map/amx_map and engine_changelevel)

    // Queued messages belong to the map being left behind; the Map Ended /
    // shutdown message below is sent immediately, outside the queue.
    Webhook_ClearQueue();
    g_bSending = false;
    g_CurrentRequest = EzHttpRequest:0;

    if (!g_bChangingMap && g_bSenderReady)
    {
        // Actual unload/shutdown: release the queue and stop the worker.
        remove_task(TASK_SEND_QUEUE);
        ArrayDestroy(g_Pending);
        g_bSenderReady = false;
    }

    new szUrl[MAX_WEBHOOK_URL];
    if (!Webhook_GetUrl(szUrl, charsmax(szUrl))) return;

    new szCurrentMap[64];
    get_mapname(szCurrentMap, charsmax(szCurrentMap));

    if (g_bChangingMap)
    {
        // Map ended - embed
        new szDesc[128];
        formatex(szDesc, charsmax(szDesc), "`%s`", szCurrentMap);
        Webhook_SendEmbedRaw("Map Ended", szDesc, 0x95A5A6, true);
    }
    else
    {
        // Server shutdown / plugin unload - plain (fire-and-forget)
        new szMsg[128];
        formatex(szMsg, charsmax(szMsg), "Server shutting down (last map: `%s`)", szCurrentMap);
        Webhook_PostPlain(szMsg, true);
    }
}

// ---------------------------------------------------------------------------
// Client connect / disconnect (non-bot only, nickname only)
// ---------------------------------------------------------------------------

public client_putinserver(id)
{
    if (is_user_bot(id) || is_user_hltv(id)) return;

    // Delay to ensure SteamID/name propagated and to avoid spam on fast reconnects.
    // Use offset task id so it never collides with TASK_CFG or other plugins' raw ids.
    remove_task(id + TASK_CONNECT_BASE);
    set_task(0.5, "Task_DelayedConnect", id + TASK_CONNECT_BASE);
}

public Task_DelayedConnect(iTaskId)
{
    new id = iTaskId - TASK_CONNECT_BASE;
    if (id < 1 || id > 32) return;
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id)) return;

    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    if (szName[0] == EOS) return;

    Webhook_SendPlain("%s connected (%d online)", szName, GetRealPlayerCount());
}

public client_disconnected(id, bool:drop, szMessage[], iMaxLen)
{
    // Requires AMXX 1.9+ (forward introduced in PR #264)
    #pragma unused drop, szMessage, iMaxLen
    // Kill any pending delayed-connect so a fast rejoin doesn't emit a stale "connected".
    remove_task(id + TASK_CONNECT_BASE);

    if (is_user_bot(id) || is_user_hltv(id)) return;

    // The entity is still valid here (the forward runs before the player is
    // removed), so the name can be read directly.
    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    if (szName[0] == EOS) return;

    // Remaining count: leaving player hasn't disconnected at this point so minus one
    new iOnline = GetRealPlayerCount() - 1;

    Webhook_SendPlain("%s disconnected (%d online)", szName, iOnline);
}

stock GetRealPlayerCount()
{
    new iCount = 0;
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_user_connected(i) && !is_user_bot(i) && !is_user_hltv(i))
        {
            iCount++;
        }
    }
    return iCount;
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

public OnChat(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
    {
        return PLUGIN_CONTINUE;
    }

    new szRaw[192];
    read_args(szRaw, charsmax(szRaw));
    remove_quotes(szRaw);
    trim(szRaw);

    if (szRaw[0] == EOS)
    {
        return PLUGIN_CONTINUE;
    }

    StripColors(szRaw, charsmax(szRaw));
    trim(szRaw);

    if (szRaw[0] == EOS)
    {
        return PLUGIN_CONTINUE;
    }

    // Filter chat commands: messages starting with / ! . ? @ are considered commands, not chat
    // This already covers single-char strings "/" and "!" so no separate check needed
    if (szRaw[0] == '/' || szRaw[0] == '!' || szRaw[0] == '.' || szRaw[0] == '?' || szRaw[0] == '@')
    {
        return PLUGIN_CONTINUE;
    }

    new szName[32];
    get_user_name(id, szName, charsmax(szName));

    // Prefixes
    new szTeamPrefix[8];
    switch (_:cs_get_user_team(id))
    {
        case CS_TEAM_T:
        {
            copy(szTeamPrefix, charsmax(szTeamPrefix), "(A)");
        }
        case CS_TEAM_CT:
        {
            copy(szTeamPrefix, charsmax(szTeamPrefix), "(D)");
        }
        default:
        {
            copy(szTeamPrefix, charsmax(szTeamPrefix), "(SPEC)");
        }
    }

    new bool:bIsDead = !is_user_alive(id);
    // Detect if say_team was used: arg 0 is "say" or "say_team"
    new szCmd[16];
    read_argv(0, szCmd, charsmax(szCmd));
    new bool:bIsTeam = equal(szCmd, "say_team") != 0;

    // Build plain chat line: e.g. "*DEAD* (A) [TEAM] Nick: hello" or "(D) Nick: hello"
    // Keep on stack small: name(32) + raw(192) + prefixes fit easily in MAX_CHAT_LEN.
    new szOut[MAX_CHAT_LEN];
    if (bIsDead && bIsTeam)
    {
        formatex(szOut, charsmax(szOut), "*DEAD* %s [TEAM] %s: %s", szTeamPrefix, szName, szRaw);
    }
    else if (bIsDead)
    {
        formatex(szOut, charsmax(szOut), "*DEAD* %s %s: %s", szTeamPrefix, szName, szRaw);
    }
    else if (bIsTeam)
    {
        formatex(szOut, charsmax(szOut), "%s [TEAM] %s: %s", szTeamPrefix, szName, szRaw);
    }
    else
    {
        formatex(szOut, charsmax(szOut), "%s %s: %s", szTeamPrefix, szName, szRaw);
    }

    Webhook_SendPlain("%s", szOut);
    return PLUGIN_CONTINUE;
}

// Strip chat color codes. In Pawn "^1".."^9" are the control bytes 0x01..0x09
// (CS uses 0x01-0x04 for colors), so strip them in one pass; also remove the
// common "!g/!y/!t" chat tags and collapse double spaces.
stock StripColors(szMsg[], iLen)
{
    new iOut = 0;
    for (new i = 0; i <= iLen && szMsg[i]; i++)
    {
        if (szMsg[i] >= 0x01 && szMsg[i] <= 0x09)
        {
            continue;
        }
        szMsg[iOut++] = szMsg[i];
    }
    szMsg[iOut] = EOS;

    replace_all(szMsg, iLen, "!g", "");
    replace_all(szMsg, iLen, "!y", "");
    replace_all(szMsg, iLen, "!t", "");
    replace_all(szMsg, iLen, "  ", " ");
}

// ---------------------------------------------------------------------------
// Round end - TeamScore + SendAudio
// ---------------------------------------------------------------------------

public OnTeamScore(iMsgId, iDest, id)
{
    // Must fit "TERRORIST" + EOS
    new szTeam[16];
    get_msg_arg_string(1, szTeam, charsmax(szTeam));
    new iScore = get_msg_arg_int(2);

    if (equal(szTeam, "TERRORIST"))
    {
        g_iTScore = iScore;
    }
    else if (equal(szTeam, "CT"))
    {
        g_iCTScore = iScore;
    }

    return PLUGIN_CONTINUE;
}

public OnTWin()
{
    // T = Attackers. Under PugMod only scoring halves count; knife rounds,
    // warmup and deathmatch are excluded (pug_state is read at event time).
    if (g_bPugStateMode)
    {
        if (!Pug_IsLiveState()) return;
        g_iTotalT++;
    }
    else if (g_bPugMode)
    {
        g_iTotalT++;
        Pug_CountRegulationRound();
    }

    // SendAudio fires before the updated TeamScore message arrives,
    // so delay the embed to let OnTeamScore update g_iTScore/g_iCTScore first.
    g_bPendingTWin = true;
    g_bPendingDraw = false;
    remove_task(TASK_ROUND);
    set_task(1.0, "Task_SendRoundEmbed", TASK_ROUND);
}

public OnCTWin()
{
    // CT = Defenders
    if (g_bPugStateMode)
    {
        if (!Pug_IsLiveState()) return;
        g_iTotalCT++;
    }
    else if (g_bPugMode)
    {
        g_iTotalCT++;
        Pug_CountRegulationRound();
    }

    g_bPendingTWin = false;
    g_bPendingDraw = false;
    remove_task(TASK_ROUND);
    set_task(1.0, "Task_SendRoundEmbed", TASK_ROUND);
}

public OnRoundDraw()
{
    if (g_bPugStateMode && !Pug_IsLiveState()) return;

    g_bPendingTWin = false;
    g_bPendingDraw = true;
    remove_task(TASK_ROUND);
    set_task(1.0, "Task_SendRoundEmbed", TASK_ROUND);
}

public Task_SendRoundEmbed(iTaskId)
{
    #pragma unused iTaskId
    Webhook_SendRoundEmbed(g_bPendingTWin, g_bPendingDraw);
}

// ---------------------------------------------------------------------------
// PugMod match state (SmileYzn/PugMod) - pug_state polling + cumulative score
// ---------------------------------------------------------------------------

// Detect PugMod through its cvars and enable the appropriate mode:
// - `pug_state`: authoritative state (PugMod writes it from SetState on every
//   transition), so poll it for halftime/restart/cancel/end/live gating.
// - `pug_rounds` + `pug_rounds_ot` without `pug_state` (older PugMod): keep the
//   round-count halftime fallback.
stock Pug_ReadConfig()
{
    remove_task(TASK_PUG_POLL);

    g_bPugMode = false;
    g_bPugFallback = false;
    g_bPugStateMode = false;
    g_pCvarPugState = 0;
    g_iPugRounds = 30;
    g_iPugRegHalf = 0;
    g_iPugOTHalf = 0;

    new pState = get_cvar_pointer("pug_state");
    new pRounds = get_cvar_pointer("pug_rounds");
    new pRoundsOT = get_cvar_pointer("pug_rounds_ot");

    // get_cvar_pointer returns 0 when the cvar does not exist (older AMXX
    // builds returned -1), so treat both as "missing".
    new bool:bHasState = (pState != 0 && pState != -1);
    new bool:bHasRounds = (pRounds != 0 && pRounds != -1);
    new bool:bHasRoundsOT = (pRoundsOT != 0 && pRoundsOT != -1);

    if (bHasRounds)
    {
        g_iPugRounds = get_pcvar_num(pRounds);
        g_iPugRegHalf = g_iPugRounds / 2;
    }

    if (bHasRoundsOT)
    {
        g_iPugOTHalf = get_pcvar_num(pRoundsOT) / 2;
    }

    if (bHasState)
    {
        g_pCvarPugState = pState;
        g_bPugStateMode = true;
        g_bPugMode = true;
        g_iPugState = Pug_ReadState();

        // 0.25s: Halftime lasts 3s and End lasts ~mp_round_restart_delay, so
        // every transition is observed well before the next one.
        set_task(0.25, "Task_PugPoll", TASK_PUG_POLL, _, _, "b");
        return;
    }

    if (bHasRounds && bHasRoundsOT && g_iPugRegHalf > 0)
    {
        g_bPugFallback = true;
        g_bPugMode = true;
    }
}

// Current CPugMod::SetState value (pug_state is a string cvar).
stock Pug_ReadState()
{
    if (!g_pCvarPugState)
    {
        return PUG_STATE_DEAD;
    }

    new szState[16];
    get_pcvar_string(g_pCvarPugState, szState, charsmax(szState));
    return str_to_num(szState);
}

// A scoring half is being played; knife rounds, warmup and deathmatch are not
// live, so they must not count towards the match score or emit round embeds.
stock bool:Pug_IsLiveState()
{
    if (!g_bPugStateMode)
    {
        return false;
    }

    new iState = Pug_ReadState();
    return (iState == PUG_STATE_FIRST_HALF
        || iState == PUG_STATE_SECOND_HALF
        || iState == PUG_STATE_OVERTIME);
}

stock bool:Pug_MatchInProgress()
{
    return (g_iTotalT > 0 || g_iTotalCT > 0 || g_iPugHalfTimes > 0);
}

// Zero cumulative score + per-half state and drop pending round/halftime
// embeds, so a restart/cancel cannot leave stale messages queued.
stock Pug_ResetMatchScore()
{
    g_iTotalT = 0;
    g_iTotalCT = 0;
    g_iPugHalfRounds = 0;
    g_iPugHalfTimes = 0;
    g_bPendingTWin = false;
    g_bPendingDraw = false;
    g_bHalftimePending = false;
    g_bHalftimeSwap = false;
    remove_task(TASK_ROUND);
    remove_task(TASK_HALFTIME);
}

// Capture the pre-swap score, apply the side swap (if any) and queue the
// Halftime embed. Swapping now keeps later round wins aligned with the new
// T/CT slots; the embed still reports the pre-swap score.
stock Pug_ScheduleHalftime(bool:bSwap, Float:fDelay)
{
    new iT = g_iTotalT;
    new iD = g_iTotalCT;

    g_iHalftimeScoreT = iT;
    g_iHalftimeScoreD = iD;
    g_bHalftimeSwap = bSwap;
    g_bHalftimePending = true;
    g_iPugHalfTimes++;
    g_iPugHalfRounds = 0;

    if (bSwap)
    {
        // Totals belong to the player group; exchanging them keeps them aligned
        // with the current T/CT slots (same as PugMod's SWAP(m_Score[...]) and
        // ReGameDLL's SwapAllPlayers).
        g_iTotalT = iD;
        g_iTotalCT = iT;
    }

    remove_task(TASK_HALFTIME);
    set_task(fDelay, "Task_Halftime", TASK_HALFTIME);
}

// Fallback halftime (older PugMod without pug_state): PugMod switches sides
// after pug_rounds/2 wins in each regulation half and after pug_rounds_ot/2
// wins in each overtime half. Only counts T/CT round wins (draws and knife
// rounds do not score).
stock Pug_CountRegulationRound()
{
    if (!g_bPugFallback) return;

    g_iPugHalfRounds++;

    new iThreshold = (g_iPugHalfTimes >= 2) ? g_iPugOTHalf : g_iPugRegHalf;

    if (iThreshold > 0 && g_iPugHalfRounds >= iThreshold)
    {
        // Fire after the 1.0s round-finished embed so Discord sees the round
        // first, then halftime. The fallback assumes a side swap.
        Pug_ScheduleHalftime(true, 1.5);
    }
}

public Task_PugPoll(iTaskId)
{
    #pragma unused iTaskId

    if (!g_bPugStateMode) return;

    new iState = Pug_ReadState();
    if (iState == g_iPugState) return;

    new iOldState = g_iPugState;
    g_iPugState = iState;
    Pug_OnStateChange(iOldState, iState);
}

stock Pug_OnStateChange(iOldState, iNewState)
{
    switch (iNewState)
    {
        case PUG_STATE_FIRST_HALF:
        {
            // Fresh match or restart. Only report a restart when a match was
            // actually in progress and had not finished normally.
            if (!g_bPugEnded && Pug_MatchInProgress())
            {
                new szDesc[192];
                formatex(szDesc, charsmax(szDesc), "A new match will start shortly. Score was (A/D): %d/%d", g_iTotalT, g_iTotalCT);
                Webhook_SendEmbedRaw("Match Restarted", szDesc, COLOR_RESTART, false);
            }

            Pug_ResetMatchScore();
            g_bPugEnded = false;
        }

        case PUG_STATE_HALFTIME:
        {
            Pug_HandleHalftime();
        }

        case PUG_STATE_SECOND_HALF, PUG_STATE_OVERTIME:
        {
            // If the 3s Halftime window was missed, apply it now so totals
            // follow the player group into the new half.
            if (iOldState == PUG_STATE_FIRST_HALF)
            {
                Pug_HandleHalftime();
            }

            g_iPugHalfRounds = 0;
        }

        case PUG_STATE_END:
        {
            // Match finished normally. Keep totals until the next match so the
            // final Round Finished embed still has its score.
            g_bPugEnded = true;
            g_bHalftimePending = false;
            g_bHalftimeSwap = false;
            remove_task(TASK_HALFTIME);
        }

        case PUG_STATE_DEATHMATCH, PUG_STATE_DEAD:
        {
            if (g_bPugEnded || !Pug_MatchInProgress()) return;

            new szDesc[192];
            formatex(szDesc, charsmax(szDesc), "The match was cancelled. Final score (A/D): %d/%d", g_iTotalT, g_iTotalCT);
            Webhook_SendEmbedRaw("Match Cancelled", szDesc, COLOR_CANCEL, false);

            Pug_ResetMatchScore();
            g_bPugEnded = false;
        }
    }
}

stock Pug_HandleHalftime()
{
    new iT = g_iTotalT;
    new iD = g_iTotalCT;

    // Mirror CPugMod::SwapTeams: at the end of regulation a tied score keeps
    // the sides (overtime) and PugMod skips SwapAllPlayers.
    new bool:bNoSwap = ((iT + iD) >= g_iPugRounds) && (iT == iD);
    Pug_ScheduleHalftime(!bNoSwap, 0.5);
}

public Task_Halftime(iTaskId)
{
    #pragma unused iTaskId

    if (!g_bHalftimePending) return;

    g_bHalftimePending = false;

    new bool:bSwap = g_bHalftimeSwap;
    g_bHalftimeSwap = false;

    new szDesc[192];

    if (bSwap)
    {
        formatex(
            szDesc, charsmax(szDesc),
            "Teams are switching sides. %s (A/D): %d/%d",
            (g_iPugHalfTimes == 1) ? "First half score" : "Score so far",
            g_iHalftimeScoreT, g_iHalftimeScoreD
        );
    }
    else
    {
        formatex(
            szDesc, charsmax(szDesc),
            "Halftime - teams keep their sides. Overtime begins. Score (A/D): %d/%d",
            g_iHalftimeScoreT, g_iHalftimeScoreD
        );
    }

    Webhook_SendEmbedRaw("Halftime", szDesc, COLOR_HALFTIME, false);
}

stock Webhook_SendRoundEmbed(bool:bTWin, bool:bDraw)
{
    new szTitle[32] = "Round Finished";
    new szDesc[128];

    // Under PugMod the game zeroes team scores at each halftime, so report the
    // plugin-side cumulative totals (which follow the player group across swaps).
    new iA = g_bPugMode ? g_iTotalT : g_iTScore;
    new iD = g_bPugMode ? g_iTotalCT : g_iCTScore;

    if (bDraw)
    {
        formatex(szDesc, charsmax(szDesc), "Round Draw! Score (A/D): %d/%d", iA, iD);
    }
    else if (bTWin)
    {
        formatex(szDesc, charsmax(szDesc), "Attackers Win! Score (A/D): %d/%d", iA, iD);
    }
    else
    {
        formatex(szDesc, charsmax(szDesc), "Defenders Win! Score (A/D): %d/%d", iA, iD);
    }

    new iColor;
    if (bDraw)
    {
        iColor = 0x95A5A6;
    }
    else if (bTWin)
    {
        iColor = 0xE74C3C; // red for Attackers
    }
    else
    {
        iColor = 0x3498DB; // blue for Defenders
    }

    Webhook_SendEmbedRaw(szTitle, szDesc, iColor, false);
}

// ---------------------------------------------------------------------------
// Webhook helpers - plain vs embed
// ---------------------------------------------------------------------------

stock Webhook_SendPlain(const szFmt[], any:...)
{
    // static = not on Pawn stack, avoids nested stack blowout
    // (OnChat szOut + this + PostPlain). Single-threaded, so safe.
    static szMsg[MAX_MSG_LEN];
    vformat(szMsg, charsmax(szMsg), szFmt, 2);
    Webhook_PostPlain(szMsg, false);
}

// Reads amx_webhook_url (trimmed). Returns false when it is unset.
stock bool:Webhook_GetUrl(szUrl[], iLen)
{
    get_pcvar_string(g_pCvarWebhookUrl, szUrl, iLen);
    trim(szUrl);
    return szUrl[0] != EOS;
}

// Applies amx_webhook_botname as the webhook username, when configured.
stock Webhook_SetBotName(EzJSON:obj)
{
    new szBotName[64];
    get_pcvar_string(g_pCvarBotName, szBotName, charsmax(szBotName));
    if (szBotName[0] != EOS)
    {
        ezjson_object_set_string(obj, "username", szBotName);
    }
}

// Creates the outbound queue and (re)starts the sender task. Idempotent; safe
// to call on every map.
stock Webhook_EnsureSender()
{
    if (!g_bSenderReady)
    {
        g_Pending = ArrayCreate(1, 32);
        g_bSenderReady = true;
    }

    g_bSending = false;
    g_CurrentRequest = EzHttpRequest:0;
    g_flTokens = RATE_CAPACITY;
    g_flTokenTime = get_gametime();
    g_flNextSend = 0.0;

    remove_task(TASK_SEND_QUEUE);
    set_task(SEND_QUEUE_TICK, "Task_SendQueue", TASK_SEND_QUEUE, _, _, "b");
}

// Drops every queued message (map change / unload).
stock Webhook_ClearQueue()
{
    if (!g_bSenderReady) return;

    new iDropped = ArraySize(g_Pending);
    while (ArraySize(g_Pending) > 0)
    {
        new DataPack:pack = ArrayGetCell(g_Pending, 0);
        ArrayDeleteItem(g_Pending, 0);
        DestroyDataPack(pack);
    }

    g_bQueueFullLogged = false;

    if (iDropped > 0)
    {
        log_amx("[Webhook] dropped %d queued message(s)", iDropped);
    }
}

// Appends a serialized request to the send queue.
stock Webhook_Enqueue(const szBody[])
{
    if (!g_bSenderReady)
    {
        Webhook_EnsureSender();
    }

    if (ArraySize(g_Pending) >= MAX_PENDING)
    {
        // Keep the most recent events: drop the oldest queued message.
        new DataPack:old = ArrayGetCell(g_Pending, 0);
        ArrayDeleteItem(g_Pending, 0);
        DestroyDataPack(old);

        if (!g_bQueueFullLogged)
        {
            log_amx("[Webhook] send queue full (%d), dropping oldest messages", MAX_PENDING);
            g_bQueueFullLogged = true;
        }
    }

    new DataPack:pack = CreateDataPack();
    WritePackCell(pack, 0); // retry count
    WritePackString(pack, szBody);
    ArrayPushCell(g_Pending, pack);
}

// Re-inserts a rate-limited request at the head of the queue.
stock Webhook_Requeue(const szBody[], iRetries)
{
    if (ArraySize(g_Pending) >= MAX_PENDING)
    {
        // The queue refilled while the request was in flight; make room.
        new DataPack:old = ArrayGetCell(g_Pending, 0);
        ArrayDeleteItem(g_Pending, 0);
        DestroyDataPack(old);
    }

    new DataPack:pack = CreateDataPack();
    WritePackCell(pack, iRetries);
    WritePackString(pack, szBody);

    if (ArraySize(g_Pending) > 0)
    {
        ArrayInsertCellBefore(g_Pending, 0, pack);
    }
    else
    {
        ArrayPushCell(g_Pending, pack);
    }
}

// Posts one serialized body through the shared EasyHttp queue.
// bForget: false = EZH_CANCEL_REQUEST (callback gets EZH_REQUEST_CANCELLED on
//                    map change),
//          true  = EZH_FORGET_REQUEST (completes after ServerDeactivate, no
//                    callback). Only plugin_end passes true so shutdown /
//                    Map Ended webhooks are not lost.
stock EzHttpRequest:Webhook_SendBody(const szBody[], const szUrl[], bool:bForget)
{
    new EzHttpOptions:opts = ezhttp_create_options();
    ezhttp_option_set_header(opts, "Content-Type", "application/json");
    ezhttp_option_set_body(opts, szBody);
    ezhttp_option_set_queue(opts, g_Queue);
    ezhttp_option_set_connect_timeout(opts, 5000);
    ezhttp_option_set_timeout(opts, 10000);
    if (bForget)
    {
        ezhttp_option_set_plugin_end_behaviour(opts, EZH_FORGET_REQUEST);
    }

    // opts variable auto-destroys itself
    return ezhttp_post(szUrl, "OnHttpComplete", opts);
}

// Serializes obj, then sends it immediately (plugin_end fire-and-forget) or
// queues it for the rate-limited sender.
stock Webhook_PostJson(EzJSON:obj, bool:bForget)
{
    new szUrl[MAX_WEBHOOK_URL];
    if (!Webhook_GetUrl(szUrl, charsmax(szUrl)))
    {
        ezjson_free(obj);
        log_amx("[Webhook] amx_webhook_url not set - dropping");
        return;
    }

    new iSize = ezjson_serial_size(obj);
    if (iSize >= MAX_BODY_LEN)
    {
        ezjson_free(obj);
        log_amx("[Webhook] message too large (%d bytes), dropping", iSize);
        return;
    }

    new szBody[MAX_BODY_LEN];
    ezjson_serial_to_string(obj, szBody, charsmax(szBody));
    ezjson_free(obj);

    if (bForget)
    {
        Webhook_SendBody(szBody, szUrl, true);
    }
    else
    {
        Webhook_Enqueue(szBody);
    }
}

// Sends at most one queued request at a time. Token bucket: RATE_CAPACITY
// immediate messages, then one every amx_webhook_rate_limit seconds.
public Task_SendQueue(iTaskId)
{
    #pragma unused iTaskId

    if (g_bSending || !g_bSenderReady || ArraySize(g_Pending) == 0)
    {
        return;
    }

    new Float:fNow = get_gametime();
    if (fNow < g_flNextSend)
    {
        return;
    }

    new Float:fInterval = get_pcvar_float(g_pCvarRateLimit);
    if (fInterval > 0.0)
    {
        g_flTokens = floatmin(RATE_CAPACITY, g_flTokens + (fNow - g_flTokenTime) / fInterval);
        g_flTokenTime = fNow;

        if (g_flTokens < 1.0)
        {
            return;
        }
    }

    new szUrl[MAX_WEBHOOK_URL];
    if (!Webhook_GetUrl(szUrl, charsmax(szUrl)))
    {
        return; // keep queued until a webhook URL is configured
    }

    new DataPack:pack = ArrayGetCell(g_Pending, 0);
    ArrayDeleteItem(g_Pending, 0);
    ResetPack(pack);
    g_iCurrentRetries = ReadPackCell(pack);
    ReadPackString(pack, g_szCurrentBody, charsmax(g_szCurrentBody));
    DestroyDataPack(pack);

    if (ArraySize(g_Pending) < MAX_PENDING)
    {
        g_bQueueFullLogged = false;
    }

    if (fInterval > 0.0)
    {
        g_flTokens -= 1.0;
    }

    g_bSending = true;
    g_CurrentRequest = Webhook_SendBody(g_szCurrentBody, szUrl, false);

    if (g_CurrentRequest == EzHttpRequest:0)
    {
        g_bSending = false;
        log_amx("[Webhook] failed to submit request");
    }
}

// Plain content POST
stock Webhook_PostPlain(const szContent[], bool:bForget)
{
    new EzJSON:obj = ezjson_init_object();
    if (obj == EzInvalid_JSON)
    {
        log_amx("[Webhook] ezjson_init_object failed");
        return;
    }

    ezjson_object_set_string(obj, "content", szContent);
    Webhook_SetBotName(obj);
    Webhook_PostJson(obj, bForget);
}

// Embed for map change (prev -> next)
stock Webhook_SendMapChangeEmbed(const szPrev[], const szNext[])
{
    new szDesc[192];
    formatex(szDesc, charsmax(szDesc), "`%s` -> `%s`", szPrev, szNext);
    Webhook_SendEmbedRaw("Map Change", szDesc, 0x3498DB, false);
}

// see bForget doc on Webhook_PostJson
stock Webhook_SendEmbedRaw(const szTitle[], const szDesc[], iColor, bool:bForget)
{
    // Build Discord embed JSON: { content:"", embeds:[{title, description, color}] }
    new EzJSON:obj = ezjson_init_object();
    new EzJSON:arr = ezjson_init_array();
    new EzJSON:embed = ezjson_init_object();

    if (obj == EzInvalid_JSON || arr == EzInvalid_JSON || embed == EzInvalid_JSON)
    {
        log_amx("[Webhook] ezjson init failed (embed)");
        if (obj != EzInvalid_JSON) ezjson_free(obj);
        if (arr != EzInvalid_JSON) ezjson_free(arr);
        if (embed != EzInvalid_JSON) ezjson_free(embed);
        return;
    }

    ezjson_object_set_string(embed, "title", szTitle);
    ezjson_object_set_string(embed, "description", szDesc);
    ezjson_object_set_number(embed, "color", iColor);

    ezjson_array_append_value(arr, embed);
    ezjson_free(embed);

    ezjson_object_set_value(obj, "embeds", arr);
    ezjson_free(arr);

    Webhook_SetBotName(obj);
    Webhook_PostJson(obj, bForget);
}

public OnHttpComplete(EzHttpRequest:request_id)
{
    // Only the single queued request we submitted is ours. Late callbacks from
    // an older map or a fire-and-forget request are ignored.
    if (!g_bSending || request_id != g_CurrentRequest)
    {
        return;
    }

    g_bSending = false;
    g_CurrentRequest = EzHttpRequest:0;

    new EzHttpErrorCode:iErr = ezhttp_get_error_code(request_id);

    // Map change / plugin unload cancels queued requests (EZH_CANCEL_REQUEST);
    // that is expected and must not be logged as a failure.
    if (iErr == EZH_REQUEST_CANCELLED)
    {
        return;
    }

    new iHttp = ezhttp_get_http_code(request_id);

    if (iHttp == 429)
    {
        // Honour Discord's advertised delay (JSON float seconds; header as a
        // fallback) and retry a bounded number of times.
        new Float:fDelay = 5.0;

        new EzJSON:resp = ezhttp_parse_json_response(request_id);
        if (resp != EzInvalid_JSON)
        {
            fDelay = ezjson_object_get_real(resp, "retry_after");
            ezjson_free(resp);
        }
        else
        {
            new szRetry[16];
            if (ezhttp_get_headers(request_id, "Retry-After", szRetry, charsmax(szRetry)))
            {
                fDelay = str_to_float(szRetry);
            }
        }

        if (fDelay < 1.0) fDelay = 1.0;
        if (fDelay > 60.0) fDelay = 60.0;

        // Discord's bucket has reset; allow the retry after the delay.
        g_flNextSend = get_gametime() + fDelay;
        g_flTokens = RATE_CAPACITY;
        g_flTokenTime = g_flNextSend;

        if (g_iCurrentRetries < MAX_RETRIES)
        {
            Webhook_Requeue(g_szCurrentBody, g_iCurrentRetries + 1);
        }
        else
        {
            log_amx("[Webhook] rate limited; dropping after %d retries", MAX_RETRIES);
        }
        return;
    }

    if (iErr != EZH_OK)
    {
        new szErr[128];
        ezhttp_get_error_message(request_id, szErr, charsmax(szErr));
        log_amx("[Webhook] POST failed err=%d http=%d msg=%s", iErr, iHttp, szErr);
    }
}
