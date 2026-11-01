-- A 2-player network game over loopback, the joiner's part (see net_game_host.lua). It joins 127.0.0.1:16121 (again
-- with a new lobby while the host's program is still starting), says hello, and launches the game the host's 'Launch'
-- names, as FAF's lobby.lua does; in the game it gives its own orders, chats with the host, answers the host's change
-- of the game's speed with one of its own, sees the host's pause, changes its own checksum of beat 250 on purpose (the
-- desync dialog on both, and our line naming the part changed, a2; NET_GAME_DESYNC: net_game_host.lua), runs past beat
-- 300 and quits after beat 310. Variants (net_game_host.lua's header):
-- NET_GAME_EJECT: it stops answering after beat 150 (moho64ui_NetTestForTests("freeze")); NET_GAME_LOADING: before it
-- is ready. Both then wait a while and quit. NET_GAME_RUN_TO: it runs on to that beat after its orders and quits.
-- NET_GAME_MAXSP: from beat 120 it reports a maxSP of -3 (message 57), from beat 230 its own measure again.
-- NET_GAME_THIRD (three programs): this file is the joiner (client 2) and, with NET_GAME_JOINER = 2, the second
-- joiner "Joiner2" (client 3): army 3 ("player") or an observer ("observer": no army; it looks through army 1 and
-- tells its commander to walk, which no copy carries out: its command source commands no army). With NET_GAME_EJECT the
-- second joiner stops answering after beat 150 (NET_GAME_SPLIT: its next beat with an order goes to the host alone,
-- then it stops) and the joiner votes it out once the host has.
--   moho64ui --init <init.lua> --prefs <a copy> --stage frontend --no-world --lua ui/tests/net_game_join.lua
--            --game-lua ui/tests/net_game_join.lua --replay-out <dir>/r --frames 2000000000 --log join.log
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
local MAXSP, THIRD, SPLIT = rawget(_G, "NET_GAME_MAXSP"), rawget(_G, "NET_GAME_THIRD"), rawget(_G, "NET_GAME_SPLIT")
local SECOND = rawget(_G, "NET_GAME_JOINER") == 2  -- (the third program: "Joiner2", client 3)
local NAME, ME = SECOND and "Joiner2" or "Joiner", SECOND and 3 or 2
local OBSERVER = SECOND and THIRD == "observer"
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
ForkThread(function()
    local stop = moho64ui_WallSeconds() + 240 + (RUN_TO or 0) / 5
    while moho64ui_WallSeconds() < stop do WaitFrames(1) end
    LOG("TEST FAIL the run took over four minutes")
    LOG("TEST done: hung")
    ExitApplication()
end)

local inGame = GetArmiesTable and GetArmiesTable()
if not inGame then
    local LobbyComm = import("/lua/ui/lobby/lobbyComm.lua")
    local lobby, welcome, failedWhy, launched = nil, nil, nil, false
    local function NewLobby()
        lobby = LobbyComm.CreateLobbyComm("TCP", 0, NAME, nil, nil)
        lobby.ConnectionToHostEstablished = function(self, localId, localName, hostId) welcome = localId end
        lobby.ConnectionFailed = function(self, reason) failedWhy = reason end
        lobby.DataReceived = function(self, data)
            if data.Type == 'Launch' then  -- (FAF's lobby.lua: each joiner launches with the host's table)
                launched = true
                self:LaunchGame(data.GameInfo)
            end
        end
        lobby.GameLaunched = function(self) LOG("TEST note: the game launched") self:Destroy() end
        lobby.LaunchFailed = function(self, why) check("the launch", why, nil) end
    end
    ForkThread(function()
        local deadline = moho64ui_WallSeconds() + 60
        repeat  -- (until the host listens)
            if lobby then lobby:Destroy() end
            failedWhy = nil
            NewLobby()
            lobby:JoinGame("127.0.0.1:16121", "Host", "0")
            WaitFor(function() return welcome ~= nil or failedWhy ~= nil end, 10)
            if not welcome then WaitFor(function() return false end, 0.5) end
        until welcome or moho64ui_WallSeconds() > deadline
        if THIRD then  -- (uid 1 or 2: the order the joiners came in)
            check("the host welcomes us", welcome == "1" or welcome == "2", true)
        else
            check("the host welcomes us", welcome, "1")
        end
        if not welcome then
            LOG("TEST done: " .. failed .. " failed")
            ExitApplication()
            return
        end
        lobby:SendData("0", { Type = 'Hello' })
        check("the host launches", WaitFor(function() return launched end, 60), true)
    end)
    return
end

-- the game
if LOADING then  -- (before the game's screen says READY: a player lost while the others load)
    moho64ui_NetTestForTests("freeze")
    ForkThread(function()
        LOG("TEST note: the joiner stops answering before it is ready")
        WaitFor(function() return false end, 40)
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
    end)
    return
end
local heard, speeds, desyncs, sawPause, console = {}, {}, {}, false, {}
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
if not EJECT and not RUN_TO and not MAXSP and not THIRD then
    if DESYNC == "unit" then moho64ui_NetTestForTests("move", 250, "1")
    elseif DESYNC == "draw" then moho64ui_NetTestForTests("draw", 230)
    else moho64ui_NetTestForTests("corrupt", 250, "a2") end
end
ForkThread(function()  -- (the host's pause, seen here)
    while not sawPause do
        if SessionIsPaused() then sawPause = true end
        WaitFrames(1)
    end
end)

local function Observe()
    -- an observer: client 3 with a command source of its own (GetSessionClients' 3), which commands no army
    -- (CLobby::LaunchGame 0x7c38c0: its source is made, 0x7c497d, and put in no army's set); its beats go to everyone as
    -- a player's do (the others wait for them)
    check("an observer: no army", GetFocusArmy(), -1)
    check("the commander comes", WaitFor(function() return GameTick() >= 60 end, 60), true)
    -- it looks through army 1 and tells its commander to walk: whatever goes out under its source, no copy's sim
    -- carries it out (Sim::IssueCommand 0x749290: not a source of that army's, no cheats)
    SetFocusArmy(1)
    check("looking through army 1", WaitFor(function() return GetFocusArmy() == 1 end, 10), true)
    local cdr = GetArmyAvatars() and GetArmyAvatars()[1]
    check("army 1's commander", cdr ~= nil, true)
    if cdr then
        local view = import("/lua/ui/game/worldview.lua").viewLeft
        local c = cdr:GetPosition()
        local cam = GetCamera("WorldCamera")
        local s = cam:SaveSettings()
        s.Focus = c
        s.Zoom = 120
        cam:RestoreSettings(s)
        WaitSeconds(1)
        SelectUnits({cdr})
        LOG("TEST note: the observer selected " .. table.getn(GetSelectedUnits() or {}) .. " at tick " .. GameTick())
        local target = {c[1] + 30, c[2], c[3] - 30}
        local d0 = VDist2(c[1], c[3], target[1], target[3])
        local at = view:Project(target)
        moho64ui_MouseMove(at.x, at.y)
        WaitFrames(2)
        moho64ui_MouseButton("Right", true, at.x, at.y)
        moho64ui_MouseButton("Right", false, at.x, at.y)
        local orderTick = GameTick()
        WaitFor(function() return GameTick() >= orderTick + 80 end, 60)
        local p = cdr:GetPosition()
        local toward = false
        for _, o in cdr:GetCommandQueue() or {} do
            if o.position and VDist2(o.position[1], o.position[3], target[1], target[3]) < 5 then toward = true end
        end
        check("the commander was not given our order", toward, false)
        check("nor came nearer to our point", VDist2(p[1], p[3], target[1], target[3]) >= d0 - 1, true)
        SelectUnits({})
    end
    SetFocusArmy(-1)
    check("back to every army", WaitFor(function() return GetFocusArmy() == -1 end, 10), true)
    if EJECT then  -- (the players vote the quiet observer out)
        WaitFor(function() return GameTick() >= 150 end, 60)
        LOG("TEST note: the observer stops answering at tick " .. GameTick())
        moho64ui_NetTestForTests("freeze")
        WaitFor(function() return false end, 30)
    else
        check("beat " .. RUN_TO .. " comes", WaitFor(function() return GameTick() >= RUN_TO end, RUN_TO / 10 * 3 + 60), true)
        check("no desync", table.getn(desyncs), 0)
        LOG("TEST note: the observer's game ends at tick " .. GameTick())
        WaitFor(function() return false end, 2)
    end
    LOG("TEST done: " .. failed .. " failed")
    ExitApplication()
end

-- the joiner's vote on the second joiner, who has gone quiet (NET_GAME_THIRD with NET_GAME_EJECT, the host's header)
local function VoteOutTheThird()
    check("the second joiner goes quiet", WaitFor(function()
        local cl = GetSessionClients()
        return cl[3] ~= nil and cl[3].connected and cl[3].quiet > 5000
    end, 60), true)
    local stood = GameTick()
    check("the host's vote reaches us", WaitFor(function() return table.getn(GetSessionClients()[3].ejectedBy) >= 1 end, 60), true)
    local cl = GetSessionClients()
    check("from the host (client 1)", cl[3] and cl[3].ejectedBy[1], 1)
    check("still connected here: we have not ejected it", cl[3] and cl[3].connected, true)
    WaitFor(function() return false end, 2)
    check("our game waits for the second joiner until we vote", GameTick(), stood)
    EjectSessionClient(3)
    check("ejected: no longer connected here", WaitFor(function() return GetSessionClients()[3].connected == false end, 5), true)
    cl = GetSessionClients()
    check("ejected by the host (client 1)", cl[3] and cl[3].ejectedBy[1], 1)
    check("and by us (client 2)", cl[3] and cl[3].ejectedBy[2], 2)
    check("the game runs on without it", WaitFor(function() return GameTick() >= stood + 60 end, 60), true)
    check("beat 265 comes", WaitFor(function() return GameTick() >= 265 end, 60), true)
    check("no desync", table.getn(desyncs), 0)
    LOG("TEST note: the second joiner stood at tick " .. stood .. "; the joiner's game ends at tick " .. GameTick())
    LOG("TEST done: " .. failed .. " failed")
    WaitFor(function() return false end, 2)
    ExitApplication()
end

ForkThread(function()
    check("a network game", SessionIsMultiplayer(), true)
    local clients = GetSessionClients()
    check(CLIENTS .. " clients", table.getn(clients), CLIENTS)
    check("we are client " .. ME, clients[ME] and clients[ME].name, NAME)
    check("and the one here", clients[ME] and clients[ME]['local'], true)
    if OBSERVER then
        check("speaking for source 3", clients[3] and clients[3].authorizedCommandSources[1], 3)
        return Observe()
    end
    check("the joiner's army", GetFocusArmy(), ME)
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
    local at = view:Project({c[1] + 20, c[2], c[3] - 25})
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
    local b = view:Project({p[1] - 8, p[2], p[3] - 8})
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
        -- from beat 120 we report -3: both games run at -3; from beat 230 our own measure again
        WaitFor(function() return GameTick() >= 120 end, 60)
        moho64ui_NetTestForTests("maxsp", 0, "-3")
        check("our game runs at -3 too", WaitFor(function() return GetSimRate() == -3 end, 5), true)
        check("our entry shows it", WaitFor(function() return GetSessionClients()[2].maxSP == -3 end, 5), true)
        check("the speed asked for stays 0", GetGameSpeed(), 0)
        local t0 = GameTick()
        WaitFrames(600)
        local beats = GameTick() - t0
        LOG("TEST note: " .. beats .. " beats in 600 frames at -3")
        check("held down: at most 65 beats in 600 frames", beats <= 65, true)
        WaitFor(function() return GameTick() >= 230 end, 120)
        moho64ui_NetTestForTests("maxsp", 0, "")
        check("measured again: we run at the speed asked for", WaitFor(function() return GetSimRate() == 0 end, 30), true)
        check("beat 300 comes", WaitFor(function() return GameTick() >= 300 end, 120), true)
        LOG("TEST note: the joiner's game ends at tick " .. GameTick())
        LOG("TEST done: " .. failed .. " failed")
        WaitFor(function() return false end, 2)
        ExitApplication()
        return
    end
    if RUN_TO then
        check("beat " .. RUN_TO .. " comes", WaitFor(function() return GameTick() >= RUN_TO end, RUN_TO / 10 * 3 + 60), true)
        check("no desync", table.getn(desyncs), 0)
        LOG("TEST note: the joiner's game ends at tick " .. GameTick() .. "; ping to the other " .. tostring(GetSessionClients()[1].ping) .. " ms")
        LOG("TEST done: " .. failed .. " failed")
        WaitFor(function() return false end, 2)
        ExitApplication()
        return
    end
    if EJECT and THIRD and not SECOND then
        return VoteOutTheThird()
    end
    if EJECT and SPLIT then
        -- our next beat with an order goes to the host alone, then we stop: the order, a walk
        WaitFor(function() return GameTick() >= 150 end, 60)
        moho64ui_NetTestForTests("split", 0, "0")
        SelectUnits({cdr})
        local q = cdr:GetPosition()
        local w = view:Project({q[1] + 15, q[2], q[3] + 15})
        moho64ui_MouseMove(w.x, w.y)
        WaitFrames(2)
        moho64ui_MouseButton("Right", true, w.x, w.y)
        moho64ui_MouseButton("Right", false, w.x, w.y)
        LOG("TEST note: the second joiner's last order at tick " .. GameTick() .. "; its beat goes to the host alone")
        local frozeAt = GameTick()
        WaitFor(function() return false end, 30)
        check("frozen, its own game stands too", GameTick() <= frozeAt + 8, true)
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
        return
    end
    if EJECT then
        WaitFor(function() return GameTick() >= 150 end, 60)
        LOG("TEST note: the joiner stops answering at tick " .. GameTick())
        moho64ui_NetTestForTests("freeze")
        local frozeAt = GameTick()
        WaitFor(function() return false end, 30)
        check("frozen, its own game stands too", GameTick() <= frozeAt + 6, true)
        LOG("TEST done: " .. failed .. " failed")
        ExitApplication()
        return
    end
    -- chat: the host's two messages arrive from the host; ours to the host alone
    check("the host's message to us arrives, from the host", WaitFor(function() return Heard("Host: host to joiner") end, 60), true)
    check("and its message to everyone", WaitFor(function() return Heard("Host: host to all") end, 10), true)
    SessionSendChatMessage({ 1 }, { NetTest = "joiner to host" })
    -- the game's speed: the host's +3 reaches us, noted as client 1's; we answer with +1
    check("the host's speed reaches us", WaitFor(function() return GetGameSpeed() == 3 end, 30), true)
    check("noted as the host's (client 1 to +3)", WaitFor(function() return Noted(speeds, "1:3") end, 5), true)
    SetGameSpeed(1)
    check("ours is taken", WaitFor(function() return GetGameSpeed() == 1 end, 10), true)
    check("and noted as ours (client 2 to +1)", WaitFor(function() return Noted(speeds, "2:1") end, 5), true)
    check("beat 310 comes", WaitFor(function() return GameTick() >= 310 end, 90), true)
    check("the host's pause was seen here", sawPause, true)
    check("the desync dialog is shown", WaitFor(function() return table.getn(desyncs) > 0 end, 10), true)
    check("naming the host", desyncs[1] and desyncs[1].who, "Host")
    check("our line names the parts that differ", WaitFor(function() return DesyncLineSaid(console, "Host") end, 10), true)
    local cl = GetSessionClients()
    check("the host is still there", cl[1] and cl[1].connected, true)
    check("our own speed note: GetGameSpeed agrees", GetGameSpeed(), 1)
    LOG("TEST note: the joiner quits at tick " .. tostring(GameTick()))
    LOG("TEST done: " .. failed .. " failed")
    ExitApplication()
end)
