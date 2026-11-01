-- The PC's own speed limit in a local game or a replay (maxSP, as the original's sim driver measures it in every
-- game: GameSession::MaxSimRate): the speed run (GetSimRate) is the smaller of the speed asked for (GetGameSpeed) and
-- this program's maxSP (GetSessionClients()[1].maxSP), the beats run at that pace, and a speed asked for reaches the
-- game's scripts as in a network game (uimain.NoteGameSpeedChanged: the score panel's "(asked / run)").
-- Run it as a game test with a configuration whose GameSpeed is "adjustable" (session_ai_nofog.lua), --seed 7,
-- --game-lua this file, --frames 1500, and one of these cases (-- /spcase <case>):
--   forced   with MOHO64UI_FORCE_MAXSP=2: +4 asked, +2 run, the beats at +2's pace
--   stepped  without it, frames stepped (no window): nothing measured, maxSP 50, +4 asked and run
--   clock    with MOHO64UI_REAL_TIME=1: measured at the PC's clock; +50 asked, our maxSP run
--   replay   from the front end (--stage frontend --lua and --game-lua this file, -- /spcase replay /spreplay <file>)
--            with MOHO64UI_FORCE_MAXSP=2: a replay is held down the same way
local failed = 0
local function check(what, got, want)
    if got == want then
        LOG("TEST ok   " .. what)
    else
        failed = failed + 1
        LOG("TEST FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end
local case = (GetCommandLineArg("/spcase", 1) or {})[1] or "forced"

if not rawget(_G, "SessionIsActive") or not SessionIsActive() then
    -- the front end (the replay case): the replay starts
    local file = (GetCommandLineArg("/spreplay", 1) or {})[1]
    LOG("TEST note the replay: " .. tostring(file))
    local started = file and LaunchReplaySession(file)
    LOG((started and "TEST ok   " or "TEST FAIL ") .. "LaunchReplaySession starts the replay")
    return
end

-- (uimain.NoteGameSpeedChanged heard: client, rate)
local uimain = import("/lua/ui/uimain.lua")
local notes = {}
local noteSpeed = uimain.NoteGameSpeedChanged
uimain.NoteGameSpeedChanged = function(client, rate)
    table.insert(notes, client .. " " .. rate)
    noteSpeed(client, rate)
end
local function lastNote() return notes[table.getn(notes)] end

-- the game's time run in `seconds` of the interface's clock
local function ran(seconds)
    local t0 = GetGameTimeSeconds()
    WaitSeconds(seconds)
    return GetGameTimeSeconds() - t0
end

ForkThread(function()
    WaitSeconds(5)  -- until the loading picture that covers the screen has faded
    local me = GetSessionClients()[1]
    LOG("TEST note case " .. case .. ": our maxSP " .. tostring(me.maxSP) .. ", GetSimRate " .. GetSimRate())
    if case == "forced" or case == "replay" then
        check("a replay: " .. tostring(case == "replay"), SessionIsReplay(), case == "replay")
        check("our maxSP is the forced one", me.maxSP, 2)
        check("at the start: asked 0", GetGameSpeed(), 0)
        check("and run 0 (below our maxSP)", GetSimRate(), 0)
        SetGameSpeed(4)
        check("SetGameSpeed(4): GetGameSpeed is the speed asked for", GetGameSpeed(), 4)
        check("GetSimRate is held down to our maxSP at once", GetSimRate(), 2)
        WaitSeconds(0.2)
        check("the scripts heard of it: uimain.NoteGameSpeedChanged(1, 4)", lastNote(), "1 4")
        local r = ran(3)
        LOG(string.format("TEST note +4 asked, +2 run: %.1f s of game time in 3 s", r))
        -- (+2: 10^0.2 = 1.585 times as fast: 4.75 s; +4 would be 7.5 s)
        check("the beats run at +2's pace (4.75 s in 3 s)", r >= 4.5 and r <= 5.1, true)
        if case == "forced" then
            local text = import("/lua/ui/game/score.lua").controls.time:GetText()
            LOG("TEST note the score panel's time: " .. tostring(text))
            check("the score panel shows asked / run", string.find(text, "(+4 / +2)", 1, true) ~= nil, true)
        end
        SetGameSpeed(1)
        check("SetGameSpeed(1): below our maxSP, run as asked", GetSimRate(), 1)
        SetGameSpeed(0)
        check("back to 0", GetSimRate(), 0)
        WaitSeconds(0.2)
        check("each change heard", table.getn(notes), 3)
    elseif case == "stepped" then
        check("frames stepped: nothing measured, our maxSP stays the start's 50", me.maxSP, 50)
        SetGameSpeed(4)
        check("SetGameSpeed(4): asked", GetGameSpeed(), 4)
        check("and run", GetSimRate(), 4)
        WaitSeconds(0.2)
        check("the scripts heard of it", lastNote(), "1 4")
        local r = ran(3)
        LOG(string.format("TEST note +4: %.1f s of game time in 3 s", r))
        check("the beats run at +4's pace (7.5 s in 3 s)", r >= 7.2 and r <= 8.0, true)
        SetGameSpeed(0)
    elseif case == "clock" then
        -- (light beats of a fraction of a millisecond measure about 20-30; 50 would mean nothing sent yet)
        check("at the PC's clock our maxSP is measured", me.maxSP ~= 50 and me.maxSP > 0, true)
        check("at 0 asked, 0 run", GetSimRate(), 0)
        SetGameSpeed(50)
        check("SetGameSpeed(50): asked", GetGameSpeed(), 50)
        -- (FAF's override of GetSessionClients, /lua/ui/override/SessionClients.lua, gives a copy made every 0.1 s: a
        -- new measure may show in GetSimRate first, so the two are asked until they agree, for at most a second)
        local function agreed()
            for i = 1, 20 do
                me = GetSessionClients()[1]
                if GetSimRate() == math.min(50, me.maxSP) then return true end
                WaitSeconds(0.05)
            end
            return false
        end
        check("run: our maxSP", agreed(), true)
        WaitSeconds(2)
        local same = agreed()
        LOG("TEST note at +50 asked: our maxSP " .. me.maxSP .. ", GetSimRate " .. GetSimRate())
        check("still the smaller of the two", same, true)
        check("held down below the speed asked for", GetSimRate() < 50, true)
        SetGameSpeed(0)
        check("back to 0", GetSimRate(), 0)
    end
    LOG("TEST done: " .. failed .. " failed")
end)
