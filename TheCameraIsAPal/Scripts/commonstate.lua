local State = { 
    ClimbHasPriority = false
    -- Add more variables as needed...
}

-- Call on every pawn (re)cache -- one line at the top of main.lua's
-- player-cache handler, before subsystems' OnPlayerCached dispatch. A
-- death mid-leap must not latch a priority across respawns.
function State.Reset()
    State.ClimbHasPriority = false
end

return State
