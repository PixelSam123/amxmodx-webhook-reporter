#pragma semicolon 1

#include <amxmodx>
#include <cstrike>
#include <easy_http>
#include <easy_http_json>

#define PLUGIN "Discord Webhook Reporter"
#define VERSION "1.2.0"
#define AUTHOR "PixelSam123"

#define MAX_WEBHOOK_URL 512
#define MAX_MSG_LEN     512
#define MAX_CHAT_LEN    384

// Task ids: never use raw player ids as task ids (collides with cfg task id 0).
// Use a dedicated base offset per task type.
#define TASK_CFG          9876
#define TASK_ROUND        9877
#define TASK_HALFTIME     9878
#define TASK_CONNECT_BASE 5000

#define COLOR_HALFTIME    0xE67E22
#define COLOR_RESTART     0xF1C40F
#define COLOR_CANCEL      0x95A5A6

new g_pCvarWebhookUrl;
new g_pCvarBotName;
new g_szWebhookUrl[MAX_WEBHOOK_URL];
new g_szBotName[64];

new g_szPrevMap[64];
new g_szNextMap[64];
new bool:g_bFirstCfg = true;
new bool:g_bChangingMap = false;

new g_iTScore;
new g_iCTScore;
new bool:g_bPendingTWin;
new bool:g_bPendingDraw;

new EzHttpQueue:g_Queue;

new g_szPlayerName[MAX_PLAYERS + 1][32];
new g_iMsgTeamScore;
new g_iMsgSayText;

// PugMod (SmileYzn/PugMod) halftime handling.
// g_bPugMode: use plugin-side cumulative totals instead of TeamScore messages
// (PugMod zeroes team slots at halftime via m_bCompleteReset and rewrites the
// TeamScore message args when pug_score_teams=1, so the raw message is not a
// reliable score source). Cumulative totals live in g_iTotalT/g_iTotalCT.
new bool:g_bPugMode;
new bool:g_bPugFallback;
new bool:g_bPugSaySeen;
new bool:g_bPugLive;
new g_iTotalT;
new g_iTotalCT;
new g_iPugRegHalf;
new g_iPugOTHalf;
new g_iPugHalfRounds;
new g_iPugHalfTimes;
new bool:g_bHalftimePending;
new bool:g_bHalftimeSwap;
// Guards duplicate restart/cancel embeds while the resulting state transition
// ("First Half started" / next match) is still pending.
new bool:g_bMatchEventGuard;

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);

    g_pCvarWebhookUrl = register_cvar("amx_webhook_url", "", FCVAR_PROTECTED);
    g_pCvarBotName    = register_cvar("amx_webhook_botname", "CS 1.6 Server");

    g_Queue = ezhttp_create_queue();
    g_iMsgTeamScore = get_user_msgid("TeamScore");
    g_iMsgSayText   = get_user_msgid("SayText");

    // PugMod broadcasts its state transitions via SayText ("... started: Get ready!!",
    // "Automatically swapping teams.") — used for halftime detection + live gating.
    if (g_iMsgSayText > 0)
    {
        register_message(g_iMsgSayText, "OnSayText");
    }

    register_clcmd("say", "OnChat");
    register_clcmd("say_team", "OnChat");

    register_event("SendAudio", "OnTWin", "a", "2&%!MRAD_terwin");
    register_event("SendAudio", "OnCTWin", "a", "2&%!MRAD_ctwin");
    register_event("SendAudio", "OnRoundDraw", "a", "2&%!MRAD_rounddraw");

    // TeamScore updates after each round; also used for generic score tracking
    register_message(g_iMsgTeamScore, "OnTeamScore");

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
    get_pcvar_string(g_pCvarWebhookUrl, g_szWebhookUrl, charsmax(g_szWebhookUrl));
    get_pcvar_string(g_pCvarBotName, g_szBotName, charsmax(g_szBotName));
    trim(g_szWebhookUrl);

    get_mapname(g_szNextMap, charsmax(g_szNextMap));

    if (g_bFirstCfg)
    {
        g_bFirstCfg = false;
        copy(g_szPrevMap, charsmax(g_szPrevMap), g_szNextMap);
        Webhook_SendPlain("Server started on map `%s`", g_szNextMap);
    }
    else
    {
        // Map change detection: plugin_cfg of new map
        if (!equal(g_szPrevMap, g_szNextMap))
        {
            Webhook_SendMapChangeEmbed(g_szPrevMap, g_szNextMap);
            copy(g_szPrevMap, charsmax(g_szPrevMap), g_szNextMap);
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
    g_bPugLive = false;
    g_bPugSaySeen = false;
    g_bPendingTWin = false;
    g_bPendingDraw = false;
    g_bHalftimePending = false;
    g_bHalftimeSwap = false;
    g_bMatchEventGuard = false;
    // Drop any pending round/halftime embed from the previous map so it
    // doesn't fire with reset scores on the new map.
    remove_task(TASK_ROUND);
    remove_task(TASK_HALFTIME);
    Pug_ReadConfig();
}

public server_changelevel(szMap[])
{
    // Engine-level map change (engine_changelevel). Mark as changing map for plugin_end differentiation
    copy(g_szNextMap, charsmax(g_szNextMap), szMap);
    g_bChangingMap = true;
}

public OnMapCmd(id, level, cid)
{
    // Any map command issued -> treat next plugin_end as map end, not shutdown
    g_bChangingMap = true;
    return PLUGIN_CONTINUE;
}

public plugin_end()
{
    // plugin_end is called on map change AND on server shutdown/unload.
    // g_bChangingMap distinguishes the two (best-effort; covers changelevel/map/amx_map and engine_changelevel)
    if (equal(g_szWebhookUrl, ""))
    {
        get_pcvar_string(g_pCvarWebhookUrl, g_szWebhookUrl, charsmax(g_szWebhookUrl));
        trim(g_szWebhookUrl);
        if (equal(g_szWebhookUrl, "")) return;
    }

    new szCurrentMap[64];
    get_mapname(szCurrentMap, charsmax(szCurrentMap));

    if (g_bChangingMap)
    {
        // Map ended — embed
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

    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));

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

    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));
    if (g_szPlayerName[id][0] == EOS) return;

    Webhook_SendPlain("%s connected (%d online)", g_szPlayerName[id], GetRealPlayerCount());
}

public client_disconnected(id, bool:drop, szMessage[], iMaxLen)
{
    // Requires AMXX 1.9+ (forward introduced in PR #264)
    #pragma unused drop, szMessage, iMaxLen
    // Kill any pending delayed-connect so a fast rejoin doesn't emit a stale "connected".
    remove_task(id + TASK_CONNECT_BASE);

    if (is_user_bot(id) || is_user_hltv(id)) return;

    // Remaining count: leaving player hasn't disconnected at this point so minus one
    new iOnline = GetRealPlayerCount() - 1;

    // g_szPlayerName still holds nickname since entity is still valid here
    if (g_szPlayerName[id][0] != EOS)
    {
        Webhook_SendPlain("%s disconnected (%d online)", g_szPlayerName[id], iOnline);
    }
    else
    {
        new szName[32];
        get_user_name(id, szName, charsmax(szName));
        if (szName[0] != EOS)
        {
            Webhook_SendPlain("%s disconnected (%d online)", szName, iOnline);
        }
    }
    g_szPlayerName[id][0] = EOS;
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
    // Update cache
    copy(g_szPlayerName[id], charsmax(g_szPlayerName[]), szName);

    // Prefixes
    new szTeamPrefix[8] = "";
    new CsTeams:iTeam = cs_get_user_team(id);
    if (iTeam == CS_TEAM_T)
    {
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(A)");
    }
    else if (iTeam == CS_TEAM_CT)
    {
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(D)");
    }
    else if (iTeam == CS_TEAM_SPECTATOR)
    {
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(SPEC)");
    }
    else
    {
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(SPEC)");
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

// Strip color codes ^1-^4 (and ^x variants). Also strip !g/!y/!t common chat colors
stock StripColors(szMsg[], iLen)
{
    // Remove ^1 ^2 ^3 ^4
    replace_all(szMsg, iLen, "^1", "");
    replace_all(szMsg, iLen, "^2", "");
    replace_all(szMsg, iLen, "^3", "");
    replace_all(szMsg, iLen, "^4", "");
    // Remove ^x01 etc. (some plugins use \x01)
    // Also strip ^0, ^5-^9 just in case
    replace_all(szMsg, iLen, "^0", "");
    replace_all(szMsg, iLen, "^5", "");
    replace_all(szMsg, iLen, "^6", "");
    replace_all(szMsg, iLen, "^7", "");
    replace_all(szMsg, iLen, "^8", "");
    replace_all(szMsg, iLen, "^9", "");
    // Remove literal color tags like !g !y !t (common in chat printers)
    // Do not strip leading ! if it's command prefix — that's already filtered above before strip
    // So here we remove embedded !g etc.
    // Simple: replace " !g " variants? We'll remove "!g", "!y", "!t" substrings
    // But keep legitimate "!" inside message? For stripping we remove those tags.
    replace_all(szMsg, iLen, "!g", "");
    replace_all(szMsg, iLen, "!y", "");
    replace_all(szMsg, iLen, "!t", "");
    // Also strip ^x color escape if somehow present as single char 0x03
    // Can't easily detect binary, but trim again
    // Replace double spaces
    replace_all(szMsg, iLen, "  ", " ");
}

// ---------------------------------------------------------------------------
// Round end — TeamScore + SendAudio
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
    // T = Attackers. Under PugMod, suppress knife round / dead-phase audio wins
    // (live flag only set while a half is being played).
    if (g_bPugMode && g_bPugSaySeen && !g_bPugLive) return;

    if (g_bPugMode)
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
    if (g_bPugMode && g_bPugSaySeen && !g_bPugLive) return;

    if (g_bPugMode)
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
    if (g_bPugMode && g_bPugSaySeen && !g_bPugLive) return;

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
// PugMod halftime (SmileYzn/PugMod) — detection + side swap + cumulative score
// ---------------------------------------------------------------------------

// Read pug_rounds / pug_rounds_ot; when present, enable cumulative match-score
// tracking and the fallback halftime calculation (no dedicated halftime event
// exists in PugMod, but it always prints SayText state messages — fallback only
// kicks in while none of them have been observed on this map).
stock Pug_ReadConfig()
{
    new pRounds = get_cvar_pointer("pug_rounds");
    new pRoundsOT = get_cvar_pointer("pug_rounds_ot");

    g_bPugFallback = false;

    if (pRounds != -1 && pRoundsOT != -1)
    {
        g_iPugRegHalf = get_pcvar_num(pRounds) / 2;
        g_iPugOTHalf = get_pcvar_num(pRoundsOT) / 2;

        if (g_iPugRegHalf > 0)
        {
            g_bPugFallback = true;
            g_bPugMode = true;
        }
    }
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

// In-place removal of HL color control bytes (0x01-0x04) that PugMod's
// PrintColor injects mid-phrase (e.g. "State changed: \x03Dead."), plus
// literal ^1-^4 remnants, so substring matching sees contiguous text.
stock StripSayControl(szMsg[], iLen)
{
    new iOut = 0;
    for (new i = 0; i <= iLen && szMsg[i]; i++)
    {
        if (szMsg[i] >= 0x01 && szMsg[i] <= 0x04) continue;
        szMsg[iOut++] = szMsg[i];
    }
    szMsg[iOut] = EOS;

    replace_all(szMsg, iLen, "^1", "");
    replace_all(szMsg, iLen, "^2", "");
    replace_all(szMsg, iLen, "^3", "");
    replace_all(szMsg, iLen, "^4", "");
}

// Fallback halftime: PugMod switches sides after pug_rounds/2 wins in each
// regulation half and after pug_rounds_ot/2 wins in each overtime half.
// Only counts T/CT round wins (draws and knife rounds do not score).
stock Pug_CountRegulationRound()
{
    if (!g_bPugFallback || g_bPugSaySeen) return;

    g_iPugHalfRounds++;

    new iThreshold = (g_iPugHalfTimes >= 2) ? g_iPugOTHalf : g_iPugRegHalf;

    if (iThreshold > 0 && g_iPugHalfRounds >= iThreshold)
    {
        g_bHalftimeSwap = true;
        g_bHalftimePending = true;
        // Fire after the 1.0s round-finished embed so Discord sees the round
        // first, then halftime.
        set_task(1.5, "Task_Halftime", TASK_HALFTIME);
    }
}

public OnSayText(iMsgId, iDest, id)
{
    #pragma unused iMsgId, iDest, id

    // SayText args: 1 = sender index, 2 = format ("%s"), 3 = message
    new szText[192];
    get_msg_arg_string(3, szText, charsmax(szText));

    if (szText[0] == EOS)
    {
        return PLUGIN_CONTINUE;
    }

    // PugMod sends state messages MSG_ONE per client: identical text arrives
    // once per recipient within the same frame — dedupe on text + gametime.
    static Float:fLastTime = -1.0;
    static szLastText[192];
    new Float:ftNow = get_gametime();

    if (ftNow == fLastTime && equal(szLastText, szText))
    {
        return PLUGIN_CONTINUE;
    }

    fLastTime = ftNow;
    copy(szLastText, charsmax(szLastText), szText);

    // PrintColor embeds color bytes inside the text — normalize before matching.
    StripSayControl(szText, charsmax(szText));

    // Hardcoded English in PugMod's CPugMod::SwapTeams — printed only when
    // sides actually switch (not on the tied regulation -> overtime halftime).
    if (containi(szText, "swapping teams") != -1)
    {
        g_bPugMode = true;
        g_bPugSaySeen = true;
        g_bHalftimeSwap = true;
        g_bHalftimePending = true;
        set_task(0.5, "Task_Halftime", TASK_HALFTIME);
        return PLUGIN_CONTINUE;
    }

    // Match restart: vote path prints "The match will be restarted." then
    // transitions to FIRST_HALF; the admin menu prints "State changed: First
    // Half." instead. The following "First Half started" is the authoritative
    // reset either way — this branch adds the embed and kills stale tasks.
    if (containi(szText, "match will be restarted") != -1
        || (containi(szText, "State changed") != -1 && containi(szText, "First Half") != -1))
    {
        g_bPugMode = true;
        g_bPugSaySeen = true;

        // Only report when a match was actually in progress: an admin forcing
        // First Half during the ready phase is not a restart.
        if (!g_bMatchEventGuard && (g_bPugLive || g_iPugHalfTimes > 0 || g_iTotalT > 0 || g_iTotalCT > 0))
        {
            new szDesc[192];
            formatex(szDesc, charsmax(szDesc), "A new match will start shortly. Score was (A/D): %d/%d", g_iTotalT, g_iTotalCT);
            Webhook_SendEmbedRaw("Match Restarted", szDesc, COLOR_RESTART, false);
        }

        g_bMatchEventGuard = true;
        g_bPugLive = false;
        Pug_ResetMatchScore();
        return PLUGIN_CONTINUE;
    }

    // Match cancel: vote path prints "The match will be cancelled." then goes
    // DEATHMATCH; admin menu prints "State changed: Dead." then DEAD.
    // "Dead" never matches inside "Deathmatch", so the admin branch is precise.
    if (containi(szText, "match will be cancelled") != -1
        || (containi(szText, "State changed") != -1 && containi(szText, "Dead") != -1))
    {
        g_bPugMode = true;
        g_bPugSaySeen = true;

        if (!g_bMatchEventGuard && (g_bPugLive || g_iPugHalfTimes > 0 || g_iTotalT > 0 || g_iTotalCT > 0))
        {
            new szDesc[192];
            formatex(szDesc, charsmax(szDesc), "The match was cancelled. Final score (A/D): %d/%d", g_iTotalT, g_iTotalCT);
            Webhook_SendEmbedRaw("Match Cancelled", szDesc, COLOR_CANCEL, false);
        }

        g_bMatchEventGuard = true;
        g_bPugLive = false;
        Pug_ResetMatchScore();
        return PLUGIN_CONTINUE;
    }

    // State transitions: "[TAG] <State> started: Get ready!!" (color codes used
    // to split phrases — text is normalized above).
    if (containi(szText, "started: Get ready") != -1)
    {
        g_bPugMode = true;
        g_bPugSaySeen = true;

        if (containi(szText, "Halftime") != -1)
        {
            // Swap message may have already scheduled this halftime; do not
            // overwrite its swap flag or restart the timer pointlessly.
            if (!g_bHalftimePending)
            {
                g_bHalftimePending = true;
                set_task(0.5, "Task_Halftime", TASK_HALFTIME);
            }
            return PLUGIN_CONTINUE;
        }

        // Knife round / captain picks also print "started: Get ready" — only
        // scoring halves count as live.
        if (containi(szText, "First Half") != -1)
        {
            // First Half always marks a fresh match start: authoritative reset
            // of cumulative totals (covers restart/cancel) and releases the
            // restart/cancel embed guard for the new match.
            g_bPugLive = true;
            Pug_ResetMatchScore();
            g_bMatchEventGuard = false;
        }
        else if (containi(szText, "Second Half") != -1 || containi(szText, "Overtime") != -1)
        {
            g_bPugLive = true;
            g_iPugHalfRounds = 0;
        }

        return PLUGIN_CONTINUE;
    }

    if (containi(szText, "End of game") != -1 || containi(szText, "Game Over") != -1)
    {
        g_bPugMode = true;
        g_bPugLive = false;
        // A halftime announced right before the match ended should not fire
        // (e.g. tie votes ending the game during the halftime pause).
        if (g_bHalftimePending)
        {
            g_bHalftimePending = false;
            g_bHalftimeSwap = false;
            remove_task(TASK_HALFTIME);
        }
    }

    return PLUGIN_CONTINUE;
}

public Task_Halftime(iTaskId)
{
    #pragma unused iTaskId

    if (!g_bHalftimePending) return;

    g_bHalftimePending = false;

    new bool:bSwap = g_bHalftimeSwap;
    g_bHalftimeSwap = false;

    g_bPugLive = false;
    g_iPugHalfRounds = 0;
    g_iPugHalfTimes++;

    new szDesc[192];

    if (bSwap)
    {
        formatex(
            szDesc, charsmax(szDesc),
            "Teams are switching sides. %s (A/D): %d/%d",
            (g_iPugHalfTimes == 1) ? "First half score" : "Score so far", g_iTotalT, g_iTotalCT
        );

        // Follow the sides across the swap: totals belong to the player group,
        // so exchanging them keeps them aligned with the current T/CT slots
        // (same semantics as PugMod's SWAP(m_Score[TERRORIST], m_Score[CT]) and
        // ReGameDLL's SwapAllPlayers).
        new iTemp = g_iTotalT;
        g_iTotalT = g_iTotalCT;
        g_iTotalCT = iTemp;
    }
    else
    {
        formatex(
            szDesc, charsmax(szDesc),
            "Halftime — teams keep their sides. Overtime begins. Score (A/D): %d/%d",
            g_iTotalT, g_iTotalCT
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
// Webhook helpers — plain vs embed
// ---------------------------------------------------------------------------

stock Webhook_SendPlain(const szFmt[], any:...)
{
    // static = not on Pawn stack, avoids nested stack blowout
    // (OnChat szOut + this + PostPlain). Single-threaded, so safe.
    static szMsg[MAX_MSG_LEN];
    vformat(szMsg, charsmax(szMsg), szFmt, 2);
    Webhook_PostPlain(szMsg, false);
}

// Plain content POST
// bForget: false=EZH_CANCEL_REQUEST (callback with EZH_REQUEST_CANCELLED on map change),
//          true =EZH_FORGET_REQUEST (fire-and-forget, completes after ServerDeactivate, no callback)
//          Only plugin_end passes true so shutdown/MapEnded webhooks are not lost.
stock Webhook_PostPlain(const szContent[], bool:bForget)
{
    if (equal(g_szWebhookUrl, ""))
    {
        get_pcvar_string(g_pCvarWebhookUrl, g_szWebhookUrl, charsmax(g_szWebhookUrl));
        trim(g_szWebhookUrl);
        if (equal(g_szWebhookUrl, ""))
        {
            log_amx("[Webhook] amx_webhook_url not set — dropping: %s", szContent);
            return;
        }
    }

    new EzJSON:obj = ezjson_init_object();
    if (obj == EzInvalid_JSON)
    {
        log_amx("[Webhook] ezjson_init_object failed");
        return;
    }

    ezjson_object_set_string(obj, "content", szContent);
    if (g_szBotName[0] != EOS)
    {
        ezjson_object_set_string(obj, "username", g_szBotName);
    }

    new EzHttpOptions:opts = ezhttp_create_options();
    ezhttp_option_set_header(opts, "Content-Type", "application/json");
    ezhttp_option_set_body_from_json(opts, obj, false);
    ezjson_free(obj);

    ezhttp_option_set_queue(opts, g_Queue);
    if (bForget)
    {
        ezhttp_option_set_plugin_end_behaviour(opts, EZH_FORGET_REQUEST);
    }

    ezhttp_post(g_szWebhookUrl, "OnHttpComplete", opts);

    // opts variable auto-destroys itself
}

// Embed for map change (prev -> next)
stock Webhook_SendMapChangeEmbed(const szPrev[], const szNext[])
{
    new szDesc[192];
    formatex(szDesc, charsmax(szDesc), "`%s` -> `%s`", szPrev, szNext);
    Webhook_SendEmbedRaw("Map Change", szDesc, 0x3498DB, false);
}

// see bForget doc on Webhook_PostPlain
stock Webhook_SendEmbedRaw(const szTitle[], const szDesc[], iColor, bool:bForget)
{
    if (equal(g_szWebhookUrl, ""))
    {
        get_pcvar_string(g_pCvarWebhookUrl, g_szWebhookUrl, charsmax(g_szWebhookUrl));
        trim(g_szWebhookUrl);
        if (equal(g_szWebhookUrl, ""))
        {
            log_amx("[Webhook] amx_webhook_url not set — dropping embed: %s", szDesc);
            return;
        }
    }

    // Build Discord embed JSON: { content:"", embeds:[{title, description, color, timestamp}] }
    new szTimestamp[32];
    format_time(szTimestamp, charsmax(szTimestamp), "%Y-%m-%dT%H:%M:%SZ", get_systime());

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
    ezjson_object_set_string(embed, "timestamp", szTimestamp);

    ezjson_array_append_value(arr, embed);
    ezjson_free(embed);

    ezjson_object_set_value(obj, "embeds", arr);
    ezjson_free(arr);

    if (g_szBotName[0] != EOS)
    {
        ezjson_object_set_string(obj, "username", g_szBotName);
    }

    new EzHttpOptions:opts = ezhttp_create_options();
    ezhttp_option_set_header(opts, "Content-Type", "application/json");
    ezhttp_option_set_body_from_json(opts, obj, false);
    ezjson_free(obj);

    ezhttp_option_set_queue(opts, g_Queue);
    if (bForget)
    {
        ezhttp_option_set_plugin_end_behaviour(opts, EZH_FORGET_REQUEST);
    }

    ezhttp_post(g_szWebhookUrl, "OnHttpComplete", opts);
}

public OnHttpComplete(EzHttpRequest:request_id)
{
    new EzHttpErrorCode:iErr = ezhttp_get_error_code(request_id);
    if (iErr != EZH_OK)
    {
        new szErr[128];
        ezhttp_get_error_message(request_id, szErr, charsmax(szErr));
        new iHttp = ezhttp_get_http_code(request_id);
        log_amx("[Webhook] POST failed err=%d http=%d msg=%s", iErr, iHttp, szErr);
    }
}
