#include <amxmodx>
#include <cstrike>
#include <easy_http>
#include <easy_http_json>

#pragma semicolon 1

#define MAX_WEBHOOK_URL 512
#define MAX_MSG_LEN     1900

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

new EzHttpQueue:g_Queue;

new g_szPlayerName[33][32];
new g_iMsgTeamScore;

public plugin_init()
{
    register_plugin("Discord Webhook Reporter", "1.0.0", "amxmodx-webhook-reporter");

    g_pCvarWebhookUrl = register_cvar("amx_webhook_url", "", FCVAR_PROTECTED);
    g_pCvarBotName    = register_cvar("amx_webhook_botname", "CS 1.6 Server");

    g_Queue = ezhttp_create_queue();
    g_iMsgTeamScore = get_user_msgid("TeamScore");

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
    set_task(0.5, "Task_ReadCvarsAndHandle");
}

public Task_ReadCvarsAndHandle()
{
    // Single place where cvars are read — after exec has completed
    get_pcvar_string(g_pCvarWebhookUrl, g_szWebhookUrl, charsmax(g_szWebhookUrl));
    get_pcvar_string(g_pCvarBotName, g_szBotName, charsmax(g_szBotName));
    trim(g_szWebhookUrl);

    get_mapname(g_szNextMap, charsmax(g_szNextMap));

    if (g_bFirstCfg)
    {
        g_bFirstCfg = false;
        copy(g_szPrevMap, charsmax(g_szPrevMap), g_szNextMap);
        Webhook_SendPlain("Plugin loaded - Server started on map `%s`", g_szNextMap);
    }
    else
    {
        // Map change detection: plugin_cfg of new map
        if (!equal(g_szPrevMap, g_szNextMap))
        {
            Webhook_SendEmbed(
                "Map Change",
                g_szPrevMap,
                g_szNextMap,
                0x3498DB
            );
            copy(g_szPrevMap, charsmax(g_szPrevMap), g_szNextMap);
        }
        // Reset map change flag after handling
        g_bChangingMap = false;
        // Scores reset on new map (engine resets, but we also reset for safety)
        g_iTScore = 0;
        g_iCTScore = 0;
    }
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
        if (equal(g_szWebhookUrl, ""))
            return;
    }

    new szCurrentMap[64];
    get_mapname(szCurrentMap, charsmax(szCurrentMap));

    if (g_bChangingMap)
    {
        // Map ended — embed
        new szDesc[128];
        formatex(szDesc, charsmax(szDesc), "Map ended: `%s`", szCurrentMap);
        Webhook_SendEmbedRaw("Map Ended", szDesc, 0x95A5A6, true);
    }
    else
    {
        // Server shutdown / plugin unload - plain (fire-and-forget)
        new szMsg[128];
        formatex(szMsg, charsmax(szMsg), "Plugin unloaded - Server shutting down (last map: %s)", szCurrentMap);
        Webhook_PostPlain(szMsg, true);
    }
}

// ---------------------------------------------------------------------------
// Client connect / disconnect (non-bot only, nickname only)
// ---------------------------------------------------------------------------

public client_authorized(id)
{
    if (is_user_bot(id) || is_user_hltv(id))
        return;
    // Cache name early; name may not be fully set yet, so also update in putinserver
    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));
}

public client_putinserver(id)
{
    if (is_user_bot(id) || is_user_hltv(id))
        return;

    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));

    // Delay to ensure SteamID/name propagated and to avoid spam on fast reconnects
    set_task(0.5, "Task_DelayedConnect", id);
}

public Task_DelayedConnect(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return;
    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));
    if (g_szPlayerName[id][0] == EOS)
        return;
    Webhook_SendPlain("%s connected", g_szPlayerName[id]);
}

public client_disconnected(id, bool:drop, szMessage[], iMaxLen)
{
    // Requires AMXX 1.9+ (forward introduced in PR #264)
    if (is_user_bot(id) || is_user_hltv(id))
        return;

    // g_szPlayerName still holds nickname since entity is still valid here
    if (g_szPlayerName[id][0] != EOS)
    {
        Webhook_SendPlain("%s disconnected", g_szPlayerName[id]);
    }
    else
    {
        new szName[32];
        get_user_name(id, szName, charsmax(szName));
        if (szName[0] != EOS)
            Webhook_SendPlain("%s disconnected", szName);
    }
    g_szPlayerName[id][0] = EOS;
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

public OnChat(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_CONTINUE;

    new szRaw[192];
    read_args(szRaw, charsmax(szRaw));
    remove_quotes(szRaw);
    trim(szRaw);

    if (szRaw[0] == EOS)
        return PLUGIN_CONTINUE;

    // Strip color codes ^1-^4 (and ^x variants). Also strip !g/!y/!t common chat colors
    StripColors(szRaw, charsmax(szRaw));
    trim(szRaw);

    if (szRaw[0] == EOS)
        return PLUGIN_CONTINUE;

    // Filter chat commands: messages starting with / ! . ? @ are considered commands, not chat
    // This already covers single-char strings "/" and "!" so no separate check needed
    if (szRaw[0] == '/' || szRaw[0] == '!' || szRaw[0] == '.' || szRaw[0] == '?' || szRaw[0] == '@')
        return PLUGIN_CONTINUE;

    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    // Update cache
    copy(g_szPlayerName[id], charsmax(g_szPlayerName[]), szName);

    // Prefixes
    new szTeamPrefix[8] = "";
    new CsTeams:iTeam = cs_get_user_team(id);
    if (iTeam == CS_TEAM_T)
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(A)");
    else if (iTeam == CS_TEAM_CT)
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(D)");
    else if (iTeam == CS_TEAM_SPECTATOR)
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(SPEC)");
    else
        copy(szTeamPrefix, charsmax(szTeamPrefix), "(SPEC)");

    new bool:bIsDead = !is_user_alive(id);
    // Detect if say_team was used: arg 0 is "say" or "say_team"
    new szCmd[16];
    read_argv(0, szCmd, charsmax(szCmd));
    new bool:bIsTeam = equal(szCmd, "say_team") != 0;

    // Build plain chat line: e.g. "*DEAD* (A) [TEAM] Nick: hello" or "(D) Nick: hello"
    new szOut[MAX_MSG_LEN];
    if (bIsDead && bIsTeam)
        formatex(szOut, charsmax(szOut), "*DEAD* %s [TEAM] %s: %s", szTeamPrefix, szName, szRaw);
    else if (bIsDead)
        formatex(szOut, charsmax(szOut), "*DEAD* %s %s: %s", szTeamPrefix, szName, szRaw);
    else if (bIsTeam)
        formatex(szOut, charsmax(szOut), "%s [TEAM] %s: %s", szTeamPrefix, szName, szRaw);
    else
        formatex(szOut, charsmax(szOut), "%s %s: %s", szTeamPrefix, szName, szRaw);

    Webhook_SendPlain("%s", szOut);
    return PLUGIN_CONTINUE;
}

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
    new szTeam[2];
    get_msg_arg_string(1, szTeam, charsmax(szTeam));
    new iScore = get_msg_arg_int(2);

    if (equal(szTeam, "TERRORIST"))
        g_iTScore = iScore;
    else if (equal(szTeam, "CT"))
        g_iCTScore = iScore;

    return PLUGIN_CONTINUE;
}

public OnTWin()
{
    // Terrorists = Attackers
    Webhook_SendRoundEmbed(true, false);
}

public OnCTWin()
{
    // CT = Defenders
    Webhook_SendRoundEmbed(false, false);
}

public OnRoundDraw()
{
    Webhook_SendRoundEmbed(false, true);
}

stock Webhook_SendRoundEmbed(bool:bTWin, bool:bDraw)
{
    new szTitle[32] = "Round Finished";
    new szDesc[128];

    if (bDraw)
        formatex(szDesc, charsmax(szDesc), "Round Draw! Score (A/D): %d/%d", g_iTScore, g_iCTScore);
    else if (bTWin)
        formatex(szDesc, charsmax(szDesc), "Attackers Win! Score (A/D): %d/%d", g_iTScore, g_iCTScore);
    else
        formatex(szDesc, charsmax(szDesc), "Defenders Win! Score (A/D): %d/%d", g_iTScore, g_iCTScore);

    new iColor;
    if (bDraw) iColor = 0x95A5A6;
    else if (bTWin) iColor = 0xE74C3C; // red for Attackers
    else iColor = 0x3498DB; // blue for Defenders

    Webhook_SendEmbedRaw(szTitle, szDesc, iColor, false);
}

// ---------------------------------------------------------------------------
// Webhook helpers — plain vs embed
// ---------------------------------------------------------------------------

stock Webhook_SendPlain(const szFmt[], any:...)
{
    new szMsg[MAX_MSG_LEN];
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

    // Escape for JSON
    new szEscaped[MAX_MSG_LEN * 2];
    JsonEscape(szContent, szEscaped, charsmax(szEscaped));

    new EzJSON:obj = ezjson_init_object();
    if (obj == EzInvalid_JSON)
    {
        log_amx("[Webhook] ezjson_init_object failed");
        return;
    }

    ezjson_object_set_string(obj, "content", szEscaped);
    if (g_szBotName[0] != EOS)
        ezjson_object_set_string(obj, "username", g_szBotName);

    new EzHttpOptions:opts = ezhttp_create_options();
    ezhttp_option_set_header(opts, "Content-Type", "application/json");
    ezhttp_option_set_body_from_json(opts, obj, false);
    ezhttp_option_set_queue(opts, g_Queue);
    if (bForget)
        ezhttp_option_set_plugin_end_behaviour(opts, EZH_FORGET_REQUEST);

    ezhttp_post(g_szWebhookUrl, "OnHttpComplete", opts);

    ezjson_free(obj);
    // opts auto-destroy
}

// Embed for map change (prev -> next)
stock Webhook_SendEmbed(const szTitle[], const szPrev[], const szNext[], iColor)
{
    new szDesc[192];
    formatex(szDesc, charsmax(szDesc), "Map changed: `%s` -> `%s`", szPrev, szNext);
    Webhook_SendEmbedRaw(szTitle, szDesc, iColor, false);
}

stock Webhook_SendEmbedRaw(const szTitle[], const szDesc[], iColor, bool:bForget) // see bForget doc on Webhook_PostPlain
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
        ezjson_object_set_string(obj, "username", g_szBotName);

    new EzHttpOptions:opts = ezhttp_create_options();
    ezhttp_option_set_header(opts, "Content-Type", "application/json");
    ezhttp_option_set_body_from_json(opts, obj, false);
    ezjson_free(obj);

    ezhttp_option_set_queue(opts, g_Queue);
    if (bForget)
        ezhttp_option_set_plugin_end_behaviour(opts, EZH_FORGET_REQUEST);

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

// ---------------------------------------------------------------------------
// JSON escape — minimal (", \, newline, carriage, tab)
// ---------------------------------------------------------------------------

stock JsonEscape(const szIn[], szOut[], iOutMax)
{
    new i, j, c;
    new iLen = strlen(szIn);
    for (i = 0, j = 0; i < iLen && j < iOutMax - 2; i++)
    {
        c = szIn[i];
        if (c == 34) // '"'
        {
            if (j + 2 >= iOutMax) break;
            szOut[j++] = 92; // '\'
            szOut[j++] = 34; // '"'
        }
        else if (c == 92) // '\'
        {
            if (j + 2 >= iOutMax) break;
            szOut[j++] = 92;
            szOut[j++] = 92;
        }
        else if (c == 10) // '\n'
        {
            if (j + 2 >= iOutMax) break;
            szOut[j++] = 92;
            szOut[j++] = 110; // 'n'
        }
        else if (c == 13) // '\r'
        {
            if (j + 2 >= iOutMax) break;
            szOut[j++] = 92;
            szOut[j++] = 114; // 'r'
        }
        else if (c == 9) // '\t'
        {
            if (j + 2 >= iOutMax) break;
            szOut[j++] = 92;
            szOut[j++] = 116; // 't'
        }
        else if (c < 32)
        {
            // Skip other control chars
            continue;
        }
        else
        {
            szOut[j++] = c;
        }
    }
    szOut[j] = EOS;
}
