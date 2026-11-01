-- Run in a launched game with --game-lua ui/tests/camera_space.lua --frames 900.
local failed = 0
local function check(name, ok)
    if not ok then failed = failed + 1 end
    LOG('TEST ' .. (ok and 'ok ' or 'FAIL ') .. name)
end
ForkThread(function()
    WaitSeconds(7)
    local cam = GetCamera('WorldCamera')
    cam:SnapTo(GetArmyAvatars()[1]:GetPosition(), nil, 60)
    WaitSeconds(0.5)
    local a = cam:SaveSettings()
    moho64ui_Key(32, '', 'down')
    moho64ui_MouseMove(600, 350)
    moho64ui_MouseMove(700, 300)
    local b = cam:SaveSettings()
    check('Space and mouse change heading', math.abs(b.Heading - a.Heading) > 0.1)
    check('Space and mouse change tilt', math.abs(b.Pitch - a.Pitch) > 0.1)
    -- Captured motion is expressed as accumulated coordinates, beyond the window.
    -- It must keep going to the world view instead of producing MouseExit.
    moho64ui_MouseMove(-100, 300)
    local c = cam:SaveSettings()
    check('camera keeps rotating past the window edge', math.abs(c.Heading - b.Heading) > 0.1)
    moho64ui_MouseMove(-150, 320)
    local d = cam:SaveSettings()
    check('captured rotation continues outside the window', math.abs(d.Heading - c.Heading) > 0.1)
    moho64ui_Key(32, '', 'up')
    WaitSeconds(1)
    local e = cam:SaveSettings()
    LOG(string.format('TEST note: release heading %.4f -> %.4f, pitch %.4f -> %.4f', a.Heading, e.Heading, a.Pitch, e.Pitch))
    -- Pitch follows zoom again on release; terrain constraints can adjust zoom
    -- slightly while the camera is turned, so allow that change in default tilt.
    check('release restores heading and tilt', math.abs(math.sin(e.Heading - a.Heading)) < 0.01 and math.abs(e.Pitch - a.Pitch) < 0.1)
    LOG('TEST done: ' .. failed .. ' failed')
end)
