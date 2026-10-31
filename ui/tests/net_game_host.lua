-- A 2-player network game over loopback, the host's part (with net_game_join.lua: two programs at once, the suite's
-- net_game in net_lobby_run.sh). In the front end it hosts on TCP port 16121 through FAF's own lobbyComm; once the
-- joiner is there it launches a game of Seton's Clutch with the host's army (1) and the joiner's (2) as FAF's lobby.lua
-- does: {Type = 'Launch', GameInfo = ...} to everyone, then its own LaunchGame. In the game both give orders (the
-- commander walks and builds a power generator); then chat both ways (SessionSendChatMessage), the game's speed
-- changed by each (both must end on the same), a pause by the host that both see, and a checksum the joiner changes on
-- purpose at beat 250 (both must show the desync dialog); they run to beat 300; the joiner then quits: its connection
-- ends, and the host ejects it at once (the original's 202 / 203) and runs on without it. Both record the game
-- (--replay-out): their fingerprints (<prefix>.fp) must be equal at every beat both ran (the runner compares them).
-- Variants (a global set in front of this file by the runner, both programs alike):
--   NET_GAME_AI: an AI army on the host's side too.
--   NET_GAME_EJECT: after the orders the joiner stops answering (moho64ui_NetTestForTests("freeze")); the host sees it
--     go quiet, ejects it (EjectSessionClient, as the disconnect dialog's button) and its game runs on without it; the
--     runner then plays the host's replay (net_game_replay.lua) and compares its fingerprints with the host's.
--   NET_GAME_LOADING: the joiner stops answering before it is ready (a player lost while loading): the host's beats
--     wait (the waiting dialog), it ejects the joiner and its game starts without it.
--   NET_GAME_DESYNC = "unit" | "draw": the joiner's desync is a true one (below, DesyncLineSaid).
--   NET_GAME_RUN_TO = <beat>: after the orders both run on to that beat and end there (no chat, speed, pause or desync):
--     a long plain game, for the beats' timing over a link with latency (MOHO64UI_REAL_TIME, MOHO64UI_NET_BEAT_LOG,
--     MOHO64_NET_DELAY_MS: docs/ui-net-game.md, "A link with latency").
--   NET_GAME_MAXSP: after the orders the joiner reports a maxSP of -3 (message 57, moho64ui_NetTestForTests("maxsp")):
--     both games run at -3 (GetSimRate), the speed asked for stays 0 (GetGameSpeed); then the joiner measures again and
--     both run at 0; they end at beat 300.
--   NET_GAME_THIRD = "player" | "observer": a third program (net_game_join.lua with NET_GAME_JOINER = 2, "Joiner2"),
--     army 3 or an observer (the configuration's Observers: client 3, a command source of its own, no army). Alone it
--     goes with NET_GAME_RUN_TO (the three run to that beat). With NET_GAME_EJECT the third stops answering after beat
--     150 and the host and the joiner both vote it out (EjectSessionClient(3)): until both have, the games wait for it.
--     NET_GAME_SPLIT besides: the third's last beat (one with an order) goes to the host alone before it stops
--     (moho64ui_NetTestForTests("split")): the joiner is a beat of it short, and both must still leave the third out
--     from the same beat (ReadyForBeat in ui/net/beat_exchange_net.cpp; MOHO64UI_NET_EJECT_RULE=original shows the
--     original's rule desync there).
--   moho64ui --init <init.lua> --prefs <a copy> --stage frontend --no-world --lua ui/tests/net_game_host.lua
--            --game-lua ui/tests/net_game_host.lua --replay-out <dir>/r --frames 2000000000 --log host.log
-- Every check logs "TEST ok ..." or "TEST FAIL ..."; the last line is "TEST done: <n> failed".
local failed = 0
local function check(what, got, want)
    if got == want then
        LOG("TEST ok   " .. what)
    else
        failed = failed + 1
        LOG("TEST FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end
local function WaitFor(cond, seconds)  -- (the PC's clock: the other program runs at its own pace)
    local deadline = moho64ui_WallSeconds() + seconds
    while not cond() and moho64ui_WallSeconds() < deadline do WaitFrames(1) end
    return cond()
end
local EJECT, LOADING = rawget(_G, "NET_GAME_EJECT"), rawget(_G, "NET_GAME_LOADING")
local RUN_TO = rawget(_G, "NET_GAME_RUN_TO")
local MAXSP, THIRD = rawget(_G, "NET_GAME_MAXSP"), rawget(_G, "NET_GAME_THIRD")
local CLIENTS = THIRD and 3 or 2
-- ours after the desync dialog: a console line naming the parts of the state that differ (GameSession::NetCompareParts),
-- the same on both programs but for the other's name. NET_GAME_DESYNC (both programs alike) picks the joiner's desync:
-- nil, its line's part a2 changed with its checksum of beat 250 (the state itself left as it is: the fingerprints stay
-- equal); "unit", army 1's first unit moved at beat 250 on the joiner only; "draw", one random number more drawn at beat
-- 230 on the joiner only (both true desyncs: the fingerprints differ from that beat on).
local DESYNC = rawget(_G, "NET_GAME_DESYNC")
local function DesyncLineSaid(lines, peer)
    local head = "Desync at beat 250 with " .. peer .. ": "
    for _, l in lines do
        if DESYNC == "unit" then
            if l == head .. "Host's units (army 1) differ (first between beats 201 and 250)" then return true end
        elseif DESYNC == "draw" then
            if string.sub(l, 1, string.len(head) + 18) == head .. "the random numbers"
               and string.find(l, "(first between beats 201 and 230)", 1, true) then return true end
        elseif l == head .. "Joiner's economy (army 2) differs (first between beats 201 and 250)" then
            return true
        end
    end
    return false
end
-- (a hang ends the run after four minutes of the PC's clock)
ForkThread(function()
    local stop = moho64ui_WallSeconds() + 240 + (RUN_TO or 0) / 5
    while moho64ui_WallSeconds() < stop do WaitFrames(1) end
    LOG("TEST FAIL the run took over four minutes")
    LOG("TEST done: hung")
    ExitApplication()
end)

local inGame = GetArmiesTable and GetArmiesTable()
if not inGame then
    local function Player(name, owner, spot)
        return { PlayerName = name, OwnerID = owner, Human = true, Civilian = false, Faction = 1, Team = 1,
                 StartSpot = spot, PlayerColor = spot, ArmyColor = spot, AIPersonality = "", Ready = true }
    end
    local config = {
        GameMods = {},
        GameOptions = { ScenarioFile = "/maps/scmp_009/scmp_009_scenario.lua", Victory = "sandbox", CheatsEnabled = "false",
                        FogOfWar = "explored", GameSpeed = "adjustable", UnitCap = "1000", Share = "ShareUntilDeath",
                        CivilianAlliance = "enemy", PrebuiltUnits = "Off", NoRushOption = "Off", Timeouts = "3",
                        TeamSpawn = "fixed", TeamLock = "locked", DisconnectionDelay02 = "90", AIReplacement = "Off" },
        Observers = {},
        PlayerOptions = {},
    }
    local lobby = import("/lua/ui/lobby/lobbyComm.lua").CreateLobbyComm("TCP", 16121, "Host", nil, nil)
    check("the lobby opens its port", lobby ~= nil, true)
    if not lobby then
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
        return
    end
    local joiner, joiner2, established = nil, nil, {}
    lobby.DataReceived = function(self, data)
        if data.Type == 'Hello' then
            if data.SenderName == "Joiner2" then joiner2 = data.SenderID else joiner = data.SenderID end
        end
    end
    lobby.EstablishedPeers = function(self, uid, peers) established[uid] = table.getn(peers) end
    lobby.GameLaunched = function(self) LOG("TEST note: the game launched") self:Destroy() end
    lobby.LaunchFailed = function(self, why) check("the launch", why, nil) end
    lobby:HostGame()
    ForkThread(function()
        check("the joiner says hello", WaitFor(function() return joiner ~= nil end, 60), true)
        if THIRD then
            check("the second joiner says hello", WaitFor(function() return joiner2 ~= nil end, 60), true)
            -- (each joiner tells everyone whom it is established with: the host and the other; the game's links are the
            -- lobby's, so they must all be up before the launch)
            check("the joiners are connected to each other", WaitFor(function()
                return joiner ~= nil and joiner2 ~= nil and established[joiner] == 2 and established[joiner2] == 2
            end, 60), true)
        end
        if not joiner or (THIRD and not joiner2) then
            LOG("TEST done: " .. failed .. " failed")
            ExitApplication()
            return
        end
        config.PlayerOptions[1] = Player("Host", lobby:GetLocalPlayerID(), 1)
        config.PlayerOptions[2] = Player("Joiner", joiner, 2)
        if THIRD == "player" then
            config.PlayerOptions[3] = Player("Joiner2", joiner2, 3)
        elseif THIRD == "observer" then  -- (FAF's lobby.lua: an observer's entry holds its name and owner)
            config.Observers[1] = { PlayerName = "Joiner2", OwnerID = joiner2 }
        end
        if rawget(_G, "NET_GAME_AI") then  -- (an AI on the host's side too: the runner's variant)
            config.PlayerOptions[3] = { PlayerName = "AI", OwnerID = lobby:GetLocalPlayerID(), Human = false, Civilian = false,
                                        Faction = 1, Team = 1, StartSpot = 3, PlayerColor = 3, ArmyColor = 3,
                                        AIPersonality = "medium", Ready = true }
        end
        WaitFor(function() return false end, 0.5)
        lobby:BroadcastData({ Type = 'Launch', GameInfo = config })  -- (FAF's lobby.lua: the host tells, then launches)
        lobby:LaunchGame(config)
    end)
    return
end

-- the game: what the engine hands the scripts is noted (the chat, the speed's changes, the desync dialog)
local heard, speeds, desyncs, console = {}, {}, {}, {}
AddConsoleOutputReciever(function(text) table.insert(console, text) end)
local gamemain = import("/lua/ui/game/gamemain.lua")
local receiveChat = gamemain.ReceiveChat
gamemain.ReceiveChat = function(sender, data)
    if type(data) == "table" and data.NetTest then table.insert(heard, sender .. ": " .. data.NetTest) end
    return receiveChat(sender, data)
end
local uimain = import("/lua/ui/uimain.lua")
local noteSpeed, showDesync = uimain.NoteGameSpeedChanged, uimain.ShowDesyncDialog
uimain.NoteGameSpeedChanged = function(client, rate)
    table.insert(speeds, client .. ":" .. rate)
    return noteSpeed(client, rate)
end
uimain.ShowDesyncDialog = function(beat, strings)
    table.insert(desyncs, { beat = beat, who = strings[1], n = table.getn(strings) })
    return showDesync(beat, strings)
end
local function Heard(line)
    for _, l in heard do if l == line then return true end end
    return false
end
local function Noted(list, entry)
    for _, l in list do if l == entry then return true end end
    return false
end

ForkThread(function()
    check("a network game", SessionIsMultiplayer(), true)
    check("the host's army", GetFocusArmy(), 1)
    check("beat 1 waits for the others' READY (after the game's screen)", GameTick(), 0)
    local clients = GetSessionClients()
    check(CLIENTS .. " clients", table.getn(clients), CLIENTS)
    check("the host is client 1 (the first army's)", clients[1] and clients[1].name, "Host")
    check("and the one here", clients[1] and clients[1]['local'], true)
    check("the joiner client 2", clients[2] and clients[2].name, "Joiner")
    check("speaking for source 2", clients[2] and clients[2].authorizedCommandSources[1], 2)
    check("nobody ejected", clients[2] and table.getn(clients[2].ejectedBy), 0)
    check("FAF's maxSP field (50 until a client's first message 57)", clients[2] and clients[2].maxSP, 50)
    if THIRD then  -- (CLobby::AssignClientIndex 0x7c4e80: the armies' owners first, then the observers)
        check("the second joiner client 3", clients[3] and clients[3].name, "Joiner2")
        check("speaking for source 3", clients[3] and clients[3].authorizedCommandSources[1], 3)
        local armyOf2 = nil
        for i, a in GetArmiesTable().armiesTable do if a.nickname == "Joiner2" then armyOf2 = i end end
        check("the second joiner's army", armyOf2, THIRD == "player" and 3 or nil)
    end
    if LOADING then
        -- the joiner never says READY: no beat runs; it goes quiet; ejected, it counts as ready and the game starts
        WaitFor(function() return false end, 3)
        check("the beats wait for the joiner's READY", GameTick(), 0)
        check("the joiner goes quiet (the disconnect dialog's cue)", WaitFor(function()
            local cl = GetSessionClients()
            return cl[2] ~= nil and cl[2].connected and cl[2].quiet > 5000
        end, 60), true)
        EjectSessionClient(2)
        check("ejected: no longer connected here", WaitFor(function() return GetSessionClients()[2].connected == false end, 5), true)
        check("the game starts without it", WaitFor(function() return GameTick() >= 40 end, 60), true)
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
        return
    end
    check("the commander comes", WaitFor(function() return GameTick() >= 60 end, 60), true)
    local view = import("/lua/ui/game/worldview.lua").viewLeft
    local cdr = GetArmyAvatars()[1]
    local c = cdr:GetPosition()
    local cam = GetCamera("WorldCamera")  -- (over the commander, as replay_record.lua)
    local s = cam:SaveSettings()
    s.Focus = c
    s.Zoom = 120
    cam:RestoreSettings(s)
    WaitSeconds(1)
    SelectUnits({cdr})
    LOG("TEST note: selected " .. table.getn(GetSelectedUnits() or {}) .. " at tick " .. GameTick())
    local at = view:Project({c[1] - 25, c[2], c[3] + 20})
    moho64ui_MouseMove(at.x, at.y)
    WaitFrames(2)
    moho64ui_MouseButton("Right", true, at.x, at.y)
    moho64ui_MouseButton("Right", false, at.x, at.y)
    local moveTick = GameTick()
    WaitFor(function() return GameTick() >= moveTick + 60 end, 60)
    local p = cdr:GetPosition()
    check("the commander walks", math.abs(p[1] - c[1]) + math.abs(p[3] - c[3]) > 8, true)
    SelectUnits({cdr})
    import("/lua/ui/game/commandmode.lua").StartCommandMode("build", {name = "ueb1101"})
    local b = view:Project({p[1] + 8, p[2], p[3] + 8})
    moho64ui_MouseMove(b.x, b.y)
    WaitSeconds(0.3)
    moho64ui_MouseButton("Left", true, b.x, b.y)
    moho64ui_MouseButton("Left", false, b.x, b.y)
    check("the commander is told to build", WaitFor(function()
        for _, o in cdr:GetCommandQueue() or {} do
            if o.type == "BuildMobile" then return true end
        end
        return false
    end, 30), true)
    if MAXSP then
        -- the joiner reports -3 from beat 120 on: the speed run here is the smaller of the speed asked for and every
        -- client's maxSP (GetSimRate 0x53e720); the speed asked for stays as it is (GetGameSpeed)
        local cl = GetSessionClients()
        LOG("TEST note: measured maxSP at tick " .. GameTick() .. ": host " .. tostring(cl[1].maxSP) .. ", joiner " ..
            tostring(cl[2].maxSP) .. "; GetSimRate " .. tostring(GetSimRate()) .. ", GetGameSpeed " .. tostring(GetGameSpeed()))
        check("the joiner reports -3", WaitFor(function() return GetSessionClients()[2].maxSP == -3 end, 60), true)
        check("our game runs at -3", WaitFor(function() return GetSimRate() == -3 end, 5), true)
        check("the speed asked for stays 0", GetGameSpeed(), 0)
        -- (each frame of a run without a window is 1/60 s of the game's clock: 600 frames are 10 s, 50 beats at -3 and
        -- 100 at 0; up to 10 more may be owed from before, the clock's most)
        local t0 = GameTick()
        WaitFrames(600)
        local beats = GameTick() - t0
        LOG("TEST note: " .. beats .. " beats in 600 frames at -3")
        check("held down: at most 65 beats in 600 frames", beats <= 65, true)
        check("the joiner measures again: its maxSP its own", WaitFor(function() return GetSessionClients()[2].maxSP ~= -3 end, 90), true)
        check("our game runs at the speed asked for again", WaitFor(function() return GetSimRate() == 0 end, 10), true)
        cl = GetSessionClients()
        LOG("TEST note: measured maxSP at tick " .. GameTick() .. ": host " .. tostring(cl[1].maxSP) .. ", joiner " .. tostring(cl[2].maxSP))
        check("beat 300 comes", WaitFor(function() return GameTick() >= 300 end, 120), true)
        LOG("TEST note: the host's game ends at tick " .. GameTick())
        LOG("TEST done: " .. failed .. " failed")
        WaitFor(function() return false end, 1)
        ExitApplication()
        return
    end
    if RUN_TO then
        -- the game runs on to that beat (all), then ends here
        check("beat " .. RUN_TO .. " comes", WaitFor(function() return GameTick() >= RUN_TO end, RUN_TO / 10 * 3 + 60), true)
        check("the joiner is still there", GetSessionClients()[2].connected, true)
        if THIRD then check("and the second joiner", GetSessionClients()[3].connected, true) end
        check("no desync", table.getn(desyncs), 0)
        LOG("TEST note: the host's game ends at tick " .. GameTick() .. "; ping to the other " .. tostring(GetSessionClients()[2].ping) .. " ms")
        LOG("TEST done: " .. failed .. " failed")
        WaitFor(function() return false end, 1)
        ExitApplication()
        return
    end
    if EJECT and THIRD then
        -- the second joiner stops answering after beat 150 (NET_GAME_SPLIT: after its last beat went to us alone): our
        -- game waits for it, it goes quiet; we vote it out, then the joiner does: until it has, the joiner's game waits
        -- for the second joiner's beats, and ours for the joiner's (a beat runs when everyone still in has every part
        -- of it: IsReadyForBeat 0x53c3e0), at most the input delay (5 beats) past where it stood
        check("the second joiner goes quiet (the disconnect dialog's cue)", WaitFor(function()
            local cl = GetSessionClients()
            return cl[3] ~= nil and cl[3].connected and cl[3].quiet > 5000
        end, 60), true)
        local stood = GameTick()
        WaitFor(function() return false end, 1)
        check("meanwhile the game waits (the tick stands)", GameTick(), stood)
        EjectSessionClient(3)
        check("ejected: no longer connected here", WaitFor(function() return GetSessionClients()[3].connected == false end, 5), true)
        WaitFor(function() return false end, 1.5)
        local cl = GetSessionClients()
        check("the joiner has not voted yet", cl[3] and table.getn(cl[3].ejectedBy), 1)
        check("our game waits for its vote (at most the input delay on)", GameTick() <= stood + 6, true)
        LOG("TEST note: the second joiner stood at tick " .. stood .. "; ours at " .. GameTick() .. " before the joiner's vote")
        check("the joiner votes too", WaitFor(function() return table.getn(GetSessionClients()[3].ejectedBy) == 2 end, 60), true)
        cl = GetSessionClients()
        check("ejected by the host (client 1)", cl[3] and cl[3].ejectedBy[1], 1)
        check("and by the joiner (client 2)", cl[3] and cl[3].ejectedBy[2], 2)
        check("the joiner is still there", cl[2] and cl[2].connected, true)
        check("the game runs on without the second joiner", WaitFor(function() return GameTick() >= stood + 60 end, 60), true)
        -- (both left it out from the same beat: the checksums of beats 200 and 250 agree)
        check("beat 265 comes", WaitFor(function() return GameTick() >= 265 end, 60), true)
        check("no desync", table.getn(desyncs), 0)
        LOG("TEST note: the host's game ends at tick " .. GameTick())
        LOG("TEST done: " .. failed .. " failed")
        WaitFor(function() return false end, 1)
        ExitApplication()
        return
    end
    if EJECT then
        -- the joiner stops answering after beat 150: our game waits for it, it goes quiet; we eject it and go on
        check("the joiner goes quiet (the disconnect dialog's cue)", WaitFor(function()
            local cl = GetSessionClients()
            return cl[2] ~= nil and cl[2].connected and cl[2].quiet > 5000
        end, 60), true)
        local stood = GameTick()
        WaitFor(function() return false end, 1)
        check("meanwhile the game waits (the tick stands)", GameTick(), stood)
        EjectSessionClient(2)
        -- (GetSessionClients is FAF's copy, /lua/ui/override/SessionClients.lua, refreshed every 0.1 s)
        check("ejected: no longer connected here", WaitFor(function() return GetSessionClients()[2].connected == false end, 5), true)
        local cl = GetSessionClients()
        check("ejected by the host (client 1)", cl[2] and cl[2].ejectedBy[1], 1)
        check("ejecting ourselves is refused", pcall(EjectSessionClient, 1), false)
        check("the game runs on without the joiner", WaitFor(function() return GameTick() >= stood + 60 end, 60), true)
        LOG("TEST note: the joiner was ejected at tick " .. stood .. "; the host's game ends at tick " .. GameTick())
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
        return
    end
    -- chat: to the joiner alone (no echo here), to everyone (the echo here too); the joiner's to us
    WaitFor(function() return GameTick() >= 150 end, 60)
    SessionSendChatMessage(2, { NetTest = "host to joiner" })
    SessionSendChatMessage({ NetTest = "host to all" })
    check("our message to everyone comes back to us, from us", WaitFor(function() return Heard("Host: host to all") end, 10), true)
    check("the joiner's message to us arrives, from the joiner", WaitFor(function() return Heard("Joiner: joiner to host") end, 30), true)
    check("our message to the joiner alone does not come back", Heard("Host: host to joiner"), false)
    check("a client that is not there is refused", pcall(SessionSendChatMessage, 3, { NetTest = "x" }), false)
    -- the game's speed: ours, then the joiner's answer; both end on the same
    SetGameSpeed(3)
    check("the speed we asked for is ours at once", GetGameSpeed(), 3)
    check("and the change is noted: client 1 to +3", WaitFor(function() return Noted(speeds, "1:3") end, 5), true)
    check("the joiner then asks for +1: we end on it", WaitFor(function() return GetGameSpeed() == 1 end, 30), true)
    check("and the change is noted: client 2 to +1", WaitFor(function() return Noted(speeds, "2:1") end, 5), true)
    -- a pause both see (the stream's own message), then on again
    SessionRequestPause()
    check("the pause comes", WaitFor(function() return SessionIsPaused() end, 20), true)
    local paused = GameTick()
    WaitFor(function() return false end, 1)
    check("while paused the tick stands", GameTick(), paused)
    SessionResume()
    check("and goes on after the resume", WaitFor(function() return GameTick() > paused + 5 end, 30), true)
    -- the joiner changed its checksum of beat 250: the desync dialog shows here, naming the joiner
    check("beat 300 comes", WaitFor(function() return GameTick() >= 300 end, 90), true)
    check("the desync dialog is shown", WaitFor(function() return table.getn(desyncs) > 0 end, 10), true)
    check("naming the joiner", desyncs[1] and desyncs[1].who, "Joiner")
    check("at the beat compared or after it", desyncs[1] ~= nil and desyncs[1].beat >= 250, true)
    LOG("TEST note: desync dialog at beat " .. tostring(desyncs[1] and desyncs[1].beat))
    check("our line names the parts that differ", WaitFor(function() return DesyncLineSaid(console, "Joiner") end, 10), true)
    -- the joiner quits after beat 310: its connection ends, and it is ejected here at once (no dialog), the game runs on
    check("the joiner, gone, is ejected at once", WaitFor(function()
        local cl = GetSessionClients()
        return cl[2] ~= nil and cl[2].connected == false
    end, 60), true)
    local left = GameTick()
    local cl = GetSessionClients()
    check("ejected by the host (client 1)", cl[2] and cl[2].ejectedBy[1], 1)
    check("near where the joiner left", left >= 300 and left <= 330, true)
    check("the console says so", WaitFor(function()
        for _, l in console do if string.find(l, "Joiner") and string.find(l, "disconnected") then return true end end
        return false
    end, 5), true)
    check("and the game runs on without it", WaitFor(function() return GameTick() >= left + 40 end, 60), true)
    LOG("TEST note: the joiner left at tick " .. tostring(left) .. "; the host's game ends at tick " .. GameTick())
    LOG("TEST done: " .. failed .. " failed")
    ExitApplication()
end)
