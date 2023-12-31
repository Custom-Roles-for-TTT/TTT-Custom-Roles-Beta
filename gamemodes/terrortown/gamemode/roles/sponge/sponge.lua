AddCSLuaFile()

local GetAllPlayers = player.GetAll

resource.AddFile("materials/particle/sponge.vmt")

-------------
-- CONVARS --
-------------

CreateConVar("ttt_sponge_notify_mode", "0", FCVAR_NONE, "The logic to use when notifying players that the sponge is killed", 0, 4)
CreateConVar("ttt_sponge_notify_sound", "0", FCVAR_NONE, "Whether to play a cheering sound when a sponge is killed", 0, 1)
CreateConVar("ttt_sponge_notify_confetti", "0", FCVAR_NONE, "Whether to throw confetti when a sponge is a killed", 0, 1)

local sponge_aura_radius = GetConVar("ttt_sponge_aura_radius")

hook.Add("TTTSyncGlobals", "Sponge_TTTSyncGlobals", function()
    SetGlobalFloat("ttt_sponge_aura_radius", sponge_aura_radius:GetInt() * UNITS_PER_METER)
end)

---------------------
-- DAMAGE TRANSFER --
---------------------

hook.Add("EntityTakeDamage", "Sponge_EntityTakeDamage", function(target, dmginfo)
    if not IsPlayer(target) then return end
    -- Don't transfer damage done to sponges, even if two sponges are next to eachother
    -- This prevents an infinite loop of transferring the damage back and forth
    if target:IsSponge() then return end

    local radius = GetGlobalFloat("ttt_sponge_aura_radius", UNITS_PER_FIVE_METERS)
    -- Check if this player is within the radius of any living sponge
    for _, p in ipairs(GetAllPlayers()) do
        if p == target then continue end
        if not p:Alive() or p:IsSpec() then continue end
        if not p:IsSponge() then continue end
        if target:GetPos():Distance(p:GetPos()) > radius then continue end

        -- If all living players are within the sponge's radius then don't transfer the damage
        local living_players = player.GetLivingInRadius(p:GetPos(), radius)
        if #living_players == #util.GetAlivePlayers() then continue end

        -- Transfer the damage to the sponge instead
        -- But before we do, check if they are going to be killed by it and record that for scoring
        local damage = dmginfo:GetDamage()
        if damage >= p:Health() then
            p:SetNWString("SpongeProtecting", target:Nick())
        end
        p:TakeDamageInfo(dmginfo)
        dmginfo:SetDamage(0)
    end
end)

----------
-- AURA --
----------

-- Calculate how much the radius should decrease per player death
local diff_per_death = 0
hook.Add("TTTBeginRound", "Sponge_AuraSize_TTTBeginRound", function()
    local radius = GetGlobalFloat("ttt_sponge_aura_radius", UNITS_PER_FIVE_METERS)
    local starting_players = #util.GetAlivePlayers()
    diff_per_death = radius / starting_players
end)

-- Decrease the aura radius for each player death
local aura_deaths = {}
hook.Add("PostPlayerDeath", "Sponge_AuraSize_PostPlayerDeath", function(ply)
    local radius = GetGlobalFloat("ttt_sponge_aura_radius", UNITS_PER_FIVE_METERS)
    SetGlobalFloat("ttt_sponge_aura_radius", radius - diff_per_death)
    aura_deaths[ply:SteamID64()] = true
end)

-- Increase the aura radius for each player who died but then respawned
hook.Add("PlayerSpawn", "Sponge_AuraSize_PlayerSpawn", function(ply, transition)
    if transition or not IsValid(ply) then return end

    local sid64 = ply:SteamID64()
    if not aura_deaths[sid64] then return end

    local radius = GetGlobalFloat("ttt_sponge_aura_radius", UNITS_PER_FIVE_METERS)
    SetGlobalFloat("ttt_sponge_aura_radius", radius + diff_per_death)
    aura_deaths[sid64] = false
end)

hook.Add("TTTPrepareRound", "Sponge_AuraSize_PrepareRound", function()
    table.Empty(aura_deaths)
end)

-- Flag a sponge when all living players are within their radius
hook.Add("Think", "Sponge_Aura_Think", function()
    local radius = GetGlobalFloat("ttt_sponge_aura_radius", UNITS_PER_FIVE_METERS)
    local alive_players = #util.GetAlivePlayers()
    for _, p in ipairs(GetAllPlayers()) do
        if not p:Alive() or p:IsSpec() then continue end
        if not p:IsSponge() then continue end

        local all_in_radius = p:GetNWBool("SpongeAllInRadius", false)
        local should_all_in_radius = alive_players == #player.GetLivingInRadius(p:GetPos(), radius)
        if all_in_radius ~= should_all_in_radius then
            p:SetNWBool("SpongeAllInRadius", should_all_in_radius)
        end
    end
end)

-----------------------
-- ROLE INTERACTIONS --
-----------------------

-- The sponge is viewable to everyone so the informant's default scan stage should be "ROLE" since their role is already known
hook.Add("TTTInformantDefaultScanStage", "Sponge_TTTInformantDefaultScanStage", function(ply, oldRole, newRole)
    if ply:IsSponge() then
        return INFORMANT_SCANNED_ROLE
    end
end)

----------------
-- WIN CHECKS --
----------------

local function SpongeKilledNotification(attacker, victim)
    JesterTeamKilledNotification(attacker, victim,
        -- getkillstring
        function()
            return attacker:Nick() .. " was overfilled the damage " .. ROLE_STRINGS[ROLE_SPONGE] .. "!"
        end)
end

hook.Add("PlayerDeath", "Sponge_WinCheck_PlayerDeath", function(victim, infl, attacker)
    local valid_kill = IsPlayer(attacker) and attacker ~= victim and GetRoundState() == ROUND_ACTIVE
    if not valid_kill then return end

    if victim:IsSponge() then
        SpongeKilledNotification(attacker, victim)
        victim:SetNWString("SpongeKiller", attacker:Nick())

        -- If we're debugging, don't end the round
        if GetConVar("ttt_debug_preventwin"):GetBool() then
            return
        end

        -- Stop the win checks so someone else doesn't steal the sponge's win
        StopWinChecks()
        -- Delay the actual end for a second so the message and sound have a chance to generate a reaction
        timer.Simple(1, function() EndRound(WIN_SPONGE) end)
    end
end)

hook.Add("TTTPrintResultMessage", "Sponge_TTTPrintResultMessage", function(type)
    if type == WIN_SPONGE then
        LANG.Msg("win_sponge", { role = ROLE_STRINGS[ROLE_SPONGE] })
        ServerLog("Result: " .. ROLE_STRINGS[ROLE_SPONGE] .. " wins.\n")
        return true
    end
end)

hook.Add("TTTPrepareRound", "Sponge_PrepareRound", function()
    for _, v in pairs(GetAllPlayers()) do
        v:SetNWString("SpongeKiller", "")
        v:SetNWString("SpongeProtecting", "")
        v:SetNWBool("SpongeAllInRadius", false)
    end
end)