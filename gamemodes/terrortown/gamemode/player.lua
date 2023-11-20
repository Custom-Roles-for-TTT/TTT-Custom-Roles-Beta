---- Player spawning/dying

local concommand = concommand
local ipairs = ipairs
local IsValid = IsValid
local math = math
local net = net
local pairs = pairs
local string = string
local table = table
local timer = timer
local util = util

local CallHook = hook.Call
local RunHook = hook.Run
local GetAllPlayers = player.GetAll
local CreateEntity = ents.Create
local FindEntsInBox = ents.FindInBox
local FindEntsByClass = ents.FindByClass

CreateConVar("ttt_bots_are_spectators", "0", FCVAR_ARCHIVE)
CreateConVar("ttt_dyingshot", "0")

CreateConVar("ttt_killer_dna_range", "550")
CreateConVar("ttt_killer_dna_basetime", "100")

local player_set_color = CreateConVar("ttt_player_set_color", "1", FCVAR_NONE, "Whether to set the player's color when they spawn", 0, 1)

-- First spawn on the server
function GM:PlayerInitialSpawn(ply)
    if not GAMEMODE.cvar_init then
        GAMEMODE:InitCvars()
    end

    ply:InitialSpawn()

    local rstate = GetRoundState() or ROUND_WAIT
    -- We should update the traitor list, if we are not about to send it
    if rstate <= ROUND_PREP then
        SendAllLists()
    end

    -- Game has started, tell this guy where the round is at
    if rstate ~= ROUND_WAIT then
        SendRoundState(rstate, ply)
        SendAllLists(ply)
    end

    -- Handle spec bots
    if ply:IsBot() and GetConVar("ttt_bots_are_spectators"):GetBool() then
        ply:SetTeam(TEAM_SPEC)
        ply:SetForceSpec(true)
    end
end

function GM:NetworkIDValidated(name, steamid)
    -- edge case where player authed after initspawn
    for _, p in ipairs(GetAllPlayers()) do
        if IsValid(p) and p:SteamID() == steamid and p.delay_karma_recall then
            KARMA.LateRecallAndSet(p)
            return
        end
    end
end

function GM:PlayerSpawn(ply)
    player_manager.SetPlayerClass(ply, "player_ttt")

    -- stop bleeding
    util.StopBleeding(ply)

    -- Some spawns may be tilted
    ply:ResetViewRoll()

    -- Clear out stuff like whether we ordered guns or what bomb code we used
    ply:ResetRoundFlags()

    -- latejoiner, send them some info
    if GetRoundState() == ROUND_ACTIVE then
        SendRoundState(GetRoundState(), ply)
    end

    ply.has_spawned = true

    -- Reset player color, transparency, and render mode
    ply:SetColor(COLOR_WHITE)
    ply:SetMaterial("")

    -- let the client do things on spawn
    net.Start("TTT_PlayerSpawned")
    net.WriteBit(ply:IsSpec())
    net.Send(ply)

    if ply:IsSpec() then
        ply:StripAll()
        ply:Spectate(OBS_MODE_ROAMING)
        return
    end

    ply:UnSpectate()

    -- Don't run the normal loadout for a player being brought back from the dead. Just give them their stored weapons
    if ply.Resurrecting then
        -- If this player had a role weapon on them when they were killed, give it back
        if ply.DeathRoleWeapons and ply.DeathRoleWeapons[ply:GetRole()] then
            for _, w in ipairs(ply.DeathRoleWeapons[ply:GetRole()]) do
                ply:Give(w)
            end
        end
    else
        RunHook("PlayerLoadout", ply)
    end

    -- ye olde hooks
    RunHook("PlayerSetModel", ply)
    RunHook("TTTPlayerSetColor", ply)

    ply:SetupHands()

    -- Reset the properties we use for tracking resurrection
    ply.Resurrecting = false
    if ply.DeathRoleWeapons then
        table.Empty(ply.DeathRoleWeapons)
    end

    SCORE:HandleSpawn(ply)
end

function GM:PlayerSetHandsModel(pl, ent)
    local simplemodel = player_manager.TranslateToPlayerModelName(pl:GetModel())
    local info = player_manager.TranslatePlayerHands(simplemodel)
    if info then
        ent:SetModel(info.model)
        ent:SetSkin(info.skin)
        ent:SetBodyGroups(info.body)
    end
end

function GM:IsSpawnpointSuitable(ply, spwn, force, rigged)
    if not IsValid(ply) or not ply:IsTerror() then return true end
    if not rigged and (not IsValid(spwn) or not spwn:IsInWorld()) then return false end

    -- spwn is normally an ent, but we sometimes use a vector for jury rigged
    -- positions
    local pos = rigged and spwn or spwn:GetPos()

    if not util.IsInWorld(pos) then return false end

    local blocking = FindEntsInBox(pos + Vector(-16, -16, 0), pos + Vector(16, 16, 64))

    for _, p in ipairs(blocking) do
        if IsPlayer(p) and p:IsTerror() and p:Alive() then
            if force then
                p:Kill()
            else
                return false
            end
        end
    end

    return true
end

local SpawnTypes = { "info_player_deathmatch", "info_player_combine",
                     "info_player_rebel", "info_player_counterterrorist", "info_player_terrorist",
                     "info_player_axis", "info_player_allies", "gmod_player_start",
                     "info_player_teamspawn" }

function GetSpawnEnts(shuffled, force_all)
    local tbl = {}
    for k, classname in ipairs(SpawnTypes) do
        for _, e in ipairs(FindEntsByClass(classname)) do
            if IsValid(e) and (not e.BeingRemoved) then
                table.insert(tbl, e)
            end
        end
    end

    -- Don't use info_player_start unless absolutely necessary, because eg. TF2
    -- uses it for observer starts that are in places where players cannot really
    -- spawn well. At all.
    if force_all or #tbl == 0 then
        for _, e in ipairs(FindEntsByClass("info_player_start")) do
            if IsValid(e) and (not e.BeingRemoved) then
                table.insert(tbl, e)
            end
        end
    end

    if shuffled then
        table.Shuffle(tbl)
    end

    return tbl
end

-- Generate points next to and above the spawn that we can test for suitability
local function PointsAroundSpawn(spwn)
    if not IsValid(spwn) then return {} end
    local pos = spwn:GetPos()

    local w = 36 -- bit roomier than player hull
    --local h = 72

    -- all rigged positions
    -- could be done without typing them out, but would take about as much time
    return {
        pos + Vector(w, 0, 0),
        pos + Vector(0, w, 0),
        pos + Vector(w, w, 0),
        pos + Vector(-w, 0, 0),
        pos + Vector(0, -w, 0),
        pos + Vector(-w, -w, 0),
        pos + Vector(-w, w, 0),
        pos + Vector(w, -w, 0)
        --pos + Vector( 0,  0,  h) -- just in case we're outside
    };
end

function GM:PlayerSelectSpawn(ply)
    if (not self.SpawnPoints) or (table.IsEmpty(self.SpawnPoints)) or (not IsTableOfEntitiesValid(self.SpawnPoints)) then

        self.SpawnPoints = GetSpawnEnts(true, false)

        -- One might think that we have to regenerate our spawnpoint
        -- cache. Otherwise, any rigged spawn entities would not get reused, and
        -- MORE new entities would be made instead. In reality, the map cleanup at
        -- round start will remove our rigged spawns, and we'll have to create new
        -- ones anyway.
    end

    if table.IsEmpty(self.SpawnPoints) then
        Error("No spawn entity found!\n")
        return
    end

    -- Just always shuffle, it's not that costly and should help spawn
    -- randomness.
    table.Shuffle(self.SpawnPoints)

    -- Optimistic attempt: assume there are sufficient spawns for all and one is
    -- free
    for _, spwn in pairs(self.SpawnPoints) do
        if self:IsSpawnpointSuitable(ply, spwn, false) then
            return spwn
        end
    end

    -- That did not work, so now look around spawns
    local picked = nil

    for _, spwn in pairs(self.SpawnPoints) do
        picked = spwn -- just to have something if all else fails

        -- See if we can jury rig a spawn near this one
        local rigged = PointsAroundSpawn(spwn)
        for _, rig in pairs(rigged) do
            if self:IsSpawnpointSuitable(ply, rig, false, true) then
                local rig_spwn = CreateEntity("info_player_terrorist")
                if IsValid(rig_spwn) then
                    rig_spwn:SetPos(rig)
                    rig_spwn:Spawn()

                    ErrorNoHalt("TTT WARNING: Map has too few spawn points, using a rigged spawn for " .. tostring(ply) .. "\n")

                    self.HaveRiggedSpawn = true
                    return rig_spwn
                end
            end
        end
    end

    -- Last attempt, force one
    for _, spwn in pairs(self.SpawnPoints) do
        if self:IsSpawnpointSuitable(ply, spwn, true) then
            return spwn
        end
    end

    return picked
end

function GM:PlayerSetModel(ply)
    local mdl = GAMEMODE.playermodel or "models/player/phoenix.mdl"
    util.PrecacheModel(mdl)
    ply:SetModel(mdl)

    -- Always clear color state, may later be changed in TTTPlayerSetColor
    ply:SetColor(COLOR_WHITE)
end

function GM:TTTPlayerSetColor(ply)
    if not player_set_color:GetBool() then return end

    local clr = COLOR_WHITE
    if GAMEMODE.playercolor then
        -- If this player has a colorable model, always use the same color as all
        -- other colorable players, so color will never be the factor that lets
        -- you tell players apart.
        clr = GAMEMODE.playercolor
    end
    ply:SetPlayerColor(Vector(clr.r / 255.0, clr.g / 255.0, clr.b / 255.0))
end


-- Only active players can use kill cmd
function GM:CanPlayerSuicide(ply)
    return ply:IsTerror()
end

function GM:PlayerSwitchFlashlight(ply, on)
    if not IsValid(ply) then return false end

    -- add the flashlight "effect" here, and then deny the switch
    -- this prevents the sound from playing, fixing the exploit
    -- where weapon sound could be silenced using the flashlight sound
    if (not on) or ply:IsTerror() then
        if on then
            ply:AddEffects(EF_DIMLIGHT)
        else
            ply:RemoveEffects(EF_DIMLIGHT)
        end
    end

    return false
end

function GM:PlayerSpray(ply)
    if not IsValid(ply) or not ply:IsTerror() then
        return true -- block
    end
end

function GM:PlayerUse(ply, ent)
    return ply:IsTerror()
end

function GM:KeyPress(ply, key)
    if not IsValid(ply) then return end

    -- Spectator keys
    if ply:IsSpec() and not ply:GetRagdollSpec() then

        if ply.propspec then
            return PROPSPEC.Key(ply, key)
        end

        if key == IN_RELOAD then
            local tgt = ply:GetObserverTarget()
            if not IsPlayer(tgt) then return end

            if not ply.spec_mode or ply.spec_mode == OBS_MODE_CHASE then
                ply.spec_mode = OBS_MODE_IN_EYE
            elseif ply.spec_mode == OBS_MODE_IN_EYE then
                ply.spec_mode = OBS_MODE_CHASE
            end
            -- roam stays roam

            ply:Spectate(ply.spec_mode)
        end

        -- If the dead player is supposed to be seeing a special spectator HUD, check if there are
        -- actions to perform on keypress and whether normal keypress stuff should be blocked
        if ply:ShouldShowSpectatorHUD() then
            local tgt = ply:GetObserverTarget()
            local powers = {}
            local skip, power_property = CallHook("TTTSpectatorHUDKeyPress", nil, ply, tgt, powers)
            if power_property then
                -- Get the player's current power and make sure they can do something with the key the pressed
                local current_power = ply:GetNWInt(power_property, 0)
                if current_power > 0 and powers[key] then
                    local action = powers[key]
                    local action_start = action.start_command
                    local action_end = action.end_command
                    local action_time = action.time
                    local action_cost = action.cost

                    -- Don't do the action if it's enabled and they have enough power
                    if action_cost > 0 and current_power >= action_cost then
                        -- Deduct the cost, run the command, and then run the un-command after the delay
                        ply:SetNWInt(power_property, current_power - action_cost)
                        tgt:ConCommand(action_start)
                        timer.Simple(action_time, function()
                            tgt:ConCommand(action_end)
                        end)
                    end
                end
            end

            if type(skip) == "boolean" and skip then
                return
            end
        end

        ply:ResetViewRoll()

        if key == IN_ATTACK then
            -- snap to random guy
            ply:Spectate(OBS_MODE_ROAMING)
            ply:SetEyeAngles(angle_zero) -- After exiting propspec, this could be set to awkward values
            ply:SpectateEntity(nil)

            local alive = util.GetAlivePlayers()

            if #alive < 1 then return end

            local target = table.Random(alive)
            if IsValid(target) then
                ply:SetPos(target:EyePos())
                ply:SetEyeAngles(target:EyeAngles())
            end
        elseif key == IN_ATTACK2 then
            -- spectate either the next guy or a random guy in chase
            local target = util.GetNextAlivePlayer(ply:GetObserverTarget())

            if IsValid(target) then
                ply:Spectate(ply.spec_mode or OBS_MODE_CHASE)
                ply:SpectateEntity(target)
            end
        elseif key == IN_DUCK then
            local pos = ply:GetPos()
            local ang = ply:EyeAngles()

            -- Only set the spectator's position to the player they are spectating if they are in chase or eye mode
            -- They can use the reload key if they want to return to the person they're spectating
            if ply:GetObserverMode() ~= OBS_MODE_ROAMING then
                local target = ply:GetObserverTarget()
                if IsPlayer(target) then
                    pos = target:EyePos()
                    ang = target:EyeAngles()
                end
            end

            -- reset
            ply:Spectate(OBS_MODE_ROAMING)
            ply:SpectateEntity(nil)

            ply:SetPos(pos)
            ply:SetEyeAngles(ang)
            return true
        elseif key == IN_JUMP then
            -- unfuck if you're on a ladder etc
            if ply:GetMoveType() ~= MOVETYPE_NOCLIP then
                ply:SetMoveType(MOVETYPE_NOCLIP)
            end
        end
    end
end

function GM:KeyRelease(ply, key)
    if key == IN_USE and IsValid(ply) and ply:IsTerror() then
        -- see if we need to do some custom usekey overriding
        local tr = util.TraceLine({
            start = ply:GetShootPos(),
            endpos = ply:GetShootPos() + ply:GetAimVector() * 84,
            filter = ply,
            mask = MASK_SHOT
        });

        if tr.Hit and IsValid(tr.Entity) then
            if tr.Entity.CanUseKey and tr.Entity.UseOverride then
                local phys = tr.Entity:GetPhysicsObject()
                if IsValid(phys) and not phys:HasGameFlag(FVPHYSICS_PLAYER_HELD) then
                    tr.Entity:UseOverride(ply)
                    return true
                else
                    -- do nothing, can't +use held objects
                    return true
                end
            elseif tr.Entity.player_ragdoll then
                CORPSE.ShowSearch(ply, tr.Entity, ply:KeyDown(IN_WALK) or ply:KeyDownLast(IN_WALK))
                return true
            end
        end
    end

end

-- Normally all dead players are blocked from IN_USE on the server, meaning we
-- can't let them search bodies. This sucks because searching bodies is
-- fun. Hence on the client we override +use for specs and use this instead.
local function SpecUseKey(ply, cmd, arg)
    if IsValid(ply) and ply:IsSpec() then
        -- longer range than normal use
        local tr = util.QuickTrace(ply:GetShootPos(), ply:GetAimVector() * 128, ply)
        if tr.Hit and IsValid(tr.Entity) then
            if tr.Entity.player_ragdoll then
                if not ply:KeyDown(IN_WALK) then
                    CORPSE.ShowSearch(ply, tr.Entity)
                else
                    ply:Spectate(OBS_MODE_IN_EYE)
                    ply:SpectateEntity(tr.Entity)
                end
            elseif tr.Entity:IsPlayer() and tr.Entity:IsActive() then
                ply:Spectate(ply.spec_mode or OBS_MODE_CHASE)
                ply:SpectateEntity(tr.Entity)
            else
                PROPSPEC.Target(ply, tr.Entity)
            end
        end
    end
end
concommand.Add("ttt_spec_use", SpecUseKey)

function GM:PlayerDisconnected(ply)
    if IsValid(ply) then
        -- Prevent the disconnecter from being in the resends
        ply:SetRole(ROLE_NONE)
        -- And clear their message queue
        ply:ResetMessageQueue()
    end

    if GetRoundState() ~= ROUND_PREP then
        SendAllLists()

        net.Start("TTT_PlayerDisconnected")
        net.WriteString(ply:Nick())
        net.Broadcast()
    end

    if KARMA.IsEnabled() then
        KARMA.Remember(ply)
    end
end

---- Death affairs

local function CreateDeathEffect(ent, marked)
    local pos = ent:GetPos() + Vector(0, 0, 20)

    local jit = 35.0

    local jitter = Vector(math.Rand(-jit, jit), math.Rand(-jit, jit), 0)
    util.PaintDown(pos + jitter, "Blood", ent)

    if marked then
        util.PaintDown(pos, "Cross", ent)
    end
end

local deathsounds = {
    Sound("player/death1.wav"),
    Sound("player/death2.wav"),
    Sound("player/death3.wav"),
    Sound("player/death4.wav"),
    Sound("player/death5.wav"),
    Sound("player/death6.wav"),
    Sound("vo/npc/male01/pain07.wav"),
    Sound("vo/npc/male01/pain08.wav"),
    Sound("vo/npc/male01/pain09.wav"),
    Sound("vo/npc/male01/pain04.wav"),
    Sound("vo/npc/Barney/ba_pain06.wav"),
    Sound("vo/npc/Barney/ba_pain07.wav"),
    Sound("vo/npc/Barney/ba_pain09.wav"),
    Sound("vo/npc/Barney/ba_ohshit03.wav"), --heh
    Sound("vo/npc/Barney/ba_no01.wav"),
    Sound("vo/npc/male01/no02.wav"),
    Sound("hostage/hpain/hpain1.wav"),
    Sound("hostage/hpain/hpain2.wav"),
    Sound("hostage/hpain/hpain3.wav"),
    Sound("hostage/hpain/hpain4.wav"),
    Sound("hostage/hpain/hpain5.wav"),
    Sound("hostage/hpain/hpain6.wav")
};

local function PlayDeathSound(victim)
    if not IsValid(victim) then return end

    sound.Play(table.Random(deathsounds), victim:GetShootPos(), 90, 100)
end

-- See if we should award credits now
local function CheckCreditAward(victim, attacker)
    if GetRoundState() ~= ROUND_ACTIVE then return end
    if not IsValid(victim) then return end

    local valid_attacker = IsPlayer(attacker)

    -- DETECTIVE AWARD
    if valid_attacker and not (victim:IsInnocentTeam() or victim:IsJesterTeam()) then
        local amt = GetConVar("ttt_det_credits_traitordead"):GetInt()

        local new_amt = CallHook("TTTRewardDetectiveTraitorDeathAmount", nil, victim, attacker, amt)
        if type(new_amt) == "number" then amt = new_amt end

        -- If size is 0, awards are off
        if amt > 0 then
            local predicate = function(p)
                if CallHook("TTTRewardDetectiveTraitorDeath", nil, p, victim, attacker, amt) then
                    return false
                end
                return p:IsActiveDetectiveTeam() or (p:IsActiveDeputy() and p:IsRoleActive())
            end

            for _, ply in ipairs(GetAllPlayers()) do
                if predicate(ply) then
                    ply:AddCredits(amt)
                end
            end

            LANG.Msg(GetDetectiveTeamFilter(true, predicate), "credit_all", { role = ROLE_STRINGS_PLURAL[ROLE_DETECTIVE], num = amt })
        end
    end

    -- TRAITOR AWARD
    if valid_attacker and not (victim:IsTraitorTeam() or victim:IsJesterTeam()) and (not GAMEMODE.AwardedCredits or GetConVar("ttt_credits_award_repeat"):GetBool()) then
        local inno_alive = 0
        local inno_dead = 0

        for _, ply in ipairs(GetAllPlayers()) do
            if not ply:IsTraitorTeam() then
                if ply:IsTerror() then
                    inno_alive = inno_alive + 1
                elseif ply:IsDeadTerror() then
                    inno_dead = inno_dead + 1
                end
            end
        end

        -- we check this at the death of an innocent who is still technically
        -- Alive(), so add one to dead count and sub one from living
        inno_dead = inno_dead + 1
        inno_alive = math.max(inno_alive - 1, 0)
        local inno_total = inno_dead + inno_alive

        -- Only repeat-award if we have reached the pct again since last time
        if GAMEMODE.AwardedCredits then
            inno_dead = inno_dead - GAMEMODE.AwardedCreditsDead
        end

        local pct = inno_dead / inno_total
        if pct >= GetConVar("ttt_credits_award_pct"):GetFloat() then
            -- Traitors have killed sufficient people to get an award
            local amt = GetConVar("ttt_credits_award_size"):GetInt()

            local new_amt = CallHook("TTTRewardTraitorInnocentDeathAmount", nil, victim, attacker, amt)
            if type(new_amt) == "number" then amt = new_amt end

            -- If size is 0, awards are off
            if amt > 0 then
                local vampire_kill_credits = GetConVar("ttt_vampire_kill_credits"):GetBool()
                local predicate = function(p)
                    if CallHook("TTTRewardTraitorInnocentDeath", nil, p, victim, attacker, amt) then
                        return false
                    end
                    if p:IsActiveTraitorTeam() and p:IsShopRole() then
                        return not p:IsVampire() or vampire_kill_credits
                    end
                    return false
                end
                LANG.Msg(GetPlayerFilter(predicate), "credit_all", { role = ROLE_STRINGS_PLURAL[ROLE_TRAITOR], num = amt })

                for _, ply in ipairs(GetAllPlayers()) do
                    if predicate(ply) then
                        ply:AddCredits(amt)
                    end
                end

                GAMEMODE.AwardedCredits = true
                GAMEMODE.AwardedCreditsDead = inno_dead + GAMEMODE.AwardedCreditsDead
            end
        end
    end
end

local offsets = {}

for i = 0, 360, 15 do
    table.insert(offsets, Vector(math.sin(i), math.cos(i), 0))
end

function FindRespawnLocation(pos)
    local midsize = Vector(33, 33, 74)
    local tstart = pos + Vector(0, 0, midsize.z / 2)

    for i = 1, #offsets do
        local o = offsets[i]
        local v = tstart + o * midsize * 1.5

        local t = {
            start = v,
            endpos = v,
            mins = midsize / -2,
            maxs = midsize / 2
        }

        local tr = util.TraceHull(t)

        if not tr.Hit then return v - Vector(0, 0, midsize.z / 2) end
    end

    return false
end

function GM:DoPlayerDeath(ply, attacker, dmginfo)
    if ply:IsSpec() then return end

    -- Experimental: Fire a last shot if ironsighting and not headshot
    if GetConVar("ttt_dyingshot"):GetBool() then
        local wep = ply:GetActiveWeapon()
        if IsValid(wep) and wep.DyingShot and not ply.was_headshot and dmginfo:IsBulletDamage() then
            local fired = wep:DyingShot()
            if fired then
                return
            end
        end

        -- Note that funny things can happen here because we fire a gun while the
        -- player is dead. Specifically, this DoPlayerDeath is run twice for
        -- him. This is ugly, and we have to return the first one to prevent crazy
        -- shit.
    end

    -- Store what non-droppable role weapons this player had when they died as this role
    -- They will be restored to the player if they are resurrected as the same role
    -- Droppable role weapons will be dropped on the ground so there's no need to give them back automatically
    ply.DeathRoleWeapons = {}
    local role_weapons = {}
    for _, w in ipairs(ply:GetWeapons()) do
        if w.Category == WEAPON_CATEGORY_ROLE and not w.AllowDrop then
            table.insert(role_weapons, WEPS.GetClass(w))
        end
    end
    ply.DeathRoleWeapons[ply:GetRole()] = role_weapons

    local valid_kill = IsPlayer(attacker) and attacker ~= ply and GetRoundState() == ROUND_ACTIVE
    -- Don't drop Swapper weapons when they are killed by a player because they are about to be resurrected anyway
    local clear_weapons = not valid_kill or not ply:IsSwapper()
    if clear_weapons then
        -- Don't drop the crowbar when a player dies
        ply:StripWeapon("weapon_zm_improvised")

        -- Drop all weapons
        for _, wep in ipairs(ply:GetWeapons()) do
            if wep ~= nil then
                WEPS.DropNotifiedWeapon(ply, wep, true) -- with ammo in them
                if wep.DampenDrop ~= nil then
                    wep:DampenDrop()
                end
            end
        end

        if IsValid(ply.hat) then
            ply.hat:Drop()
        end
    end

    -- Create ragdoll and hook up marking effects
    local rag = CORPSE.Create(ply, attacker, dmginfo)
    ply.server_ragdoll = rag -- nil if clientside

    CreateDeathEffect(ply, false)

    util.StartBleeding(rag, dmginfo:GetDamage(), 15)

    -- Score only when there is a round active.
    if GetRoundState() == ROUND_ACTIVE then
        SCORE:HandleKill(ply, attacker, dmginfo)

        if IsPlayer(attacker) then
            attacker:RecordKill(ply)

            if GetConVar("ttt_debug_logkills"):GetBool() then
                DamageLog(Format("KILL:\t %s [%s] killed %s [%s]", attacker:Nick(), ROLE_STRINGS[attacker:GetRole()], ply:Nick(), ROLE_STRINGS[ply:GetRole()]))
            end
        elseif GetConVar("ttt_debug_logkills"):GetBool() then
            DamageLog(Format("KILL:\t <something/world> killed %s [%s]", ply:Nick(), ROLE_STRINGS[ply:GetRole()]))
        end

        KARMA.Killed(attacker, ply, dmginfo)
    end

    -- Clear out any weapon or equipment we still have
    if clear_weapons then
        ply:StripAll()
    end

    -- Tell the client to send their chat contents
    ply:SendLastWords(dmginfo)

    local killwep = util.WeaponFromDamage(dmginfo)

    -- headshots, knife damage, and weapons tagged as silent all prevent death
    -- sound from occurring
    if not (ply.was_headshot or
            dmginfo:IsDamageType(DMG_SLASH) or
            (IsValid(killwep) and killwep.IsSilent)) then
        PlayDeathSound(ply)
    end

    --- Credits

    CheckCreditAward(ply, attacker)

    -- Check for T killing D or vice versa
    if IsPlayer(attacker) then
        local reward = 0
        if attacker:IsActiveTraitorTeam() and ply:IsDetectiveTeam() then
            reward = math.ceil(GetConVar("ttt_credits_detectivekill"):GetInt())
        elseif (attacker:IsActiveDetectiveTeam() or (attacker:IsActiveDeputy() and attacker:IsRoleActive())) and ply:IsTraitorTeam() then
            reward = math.ceil(GetConVar("ttt_det_credits_traitorkill"):GetInt())
        end

        local new_reward = CallHook("TTTRewardPlayerKilledAmount", nil, ply, attacker, reward)
        if type(new_reward) == "number" then reward = new_reward end

        if reward > 0 then
            attacker:AddCredits(reward)

            LANG.Msg(attacker, "credit_kill", { num = reward,
                                                role = ROLE_STRINGS_EXT[ply:GetRole()] })
        end
    end

    ply:SetTeam(TEAM_SPEC)
end

function GM:PlayerDeath(victim, infl, attacker)
    -- stop bleeding
    util.StopBleeding(victim)

    -- tell no one
    self:PlayerSilentDeath(victim)

    victim:Freeze(false)

    victim:SetRagdollSpec(true)
    victim:Spectate(OBS_MODE_IN_EYE)

    local rag_ent = victim.server_ragdoll or victim:GetRagdollEntity()
    victim:SpectateEntity(rag_ent)

    victim:Flashlight(false)

    victim:Extinguish()
    victim.ignite_info = nil

    net.Start("TTT_PlayerDied")
    net.Send(victim)

    if HasteMode() and GetRoundState() == ROUND_ACTIVE then
        IncRoundEnd(GetConVar("ttt_haste_minutes_per_death"):GetFloat() * 60)
    end
end

-- kill hl2 beep
function GM:PlayerDeathSound() return true end

function GM:SpectatorThink(ply)
    -- when spectating a ragdoll after death
    if ply:GetRagdollSpec() then
        local to_switch, to_chase, to_roam = 2, 5, 8
        local elapsed = CurTime() - ply.spec_ragdoll_start
        local clicked = ply:KeyPressed(IN_ATTACK)

        -- After first click, go into chase cam, then after another click, to into
        -- roam. If no clicks made, go into chase after X secs, and roam after Y.
        -- Don't switch for a second in case the player was shooting when they died,
        -- this would make them accidentally switch out of ragdoll cam.

        local m = ply:GetObserverMode()
        if (m == OBS_MODE_CHASE and clicked) or elapsed > to_roam then
            -- free roam mode
            ply:SetRagdollSpec(false)
            ply:Spectate(OBS_MODE_ROAMING)

            -- move to spectator spawn if mapper defined any
            local spec_spawns = FindEntsByClass("ttt_spectator_spawn")
            if spec_spawns and #spec_spawns > 0 then
                local spawn = table.Random(spec_spawns)
                ply:SetPos(spawn:GetPos())
                ply:SetEyeAngles(spawn:GetAngles())
            end
        elseif (m == OBS_MODE_IN_EYE and clicked and elapsed > to_switch) or elapsed > to_chase then
            -- start following ragdoll
            ply:Spectate(OBS_MODE_CHASE)
        end

        if not IsValid(ply.server_ragdoll) then ply:SetRagdollSpec(false) end

        -- when roaming and messing with ladders
    elseif ply:GetMoveType() < MOVETYPE_NOCLIP and ply:GetMoveType() > 0 or ply:GetMoveType() == MOVETYPE_LADDER then
        ply:Spectate(OBS_MODE_ROAMING)
    end

    -- when speccing a player
    if ply:GetObserverMode() ~= OBS_MODE_ROAMING and (not ply.propspec) and (not ply:GetRagdollSpec()) then
        local tgt = ply:GetObserverTarget()
        if IsPlayer(tgt) then
            if (not tgt:IsTerror()) or (not tgt:Alive()) then
                -- stop speccing as soon as target dies
                ply:Spectate(OBS_MODE_ROAMING)
                ply:SpectateEntity(nil)
            elseif GetRoundState() == ROUND_ACTIVE then
                -- Sync position to target. Uglier than parenting, but unlike
                -- parenting this is less sensitive to breakage: if we are
                -- no longer spectating, we will never sync to their position.
                ply:SetPos(tgt:GetPos())
            end
        end
    end
end

GM.PlayerDeathThink = GM.SpectatorThink

function GM:PlayerTraceAttack(ply, dmginfo, dir, trace)
    if IsValid(ply.hat) and trace.HitGroup == HITGROUP_HEAD then
        ply.hat:Drop(dir)
    end

    ply.hit_trace = trace

    return false
end

function GM:ScalePlayerDamage(ply, hitgroup, dmginfo)
    -- Body armor nets you a damage reduction.
    if dmginfo:IsBulletDamage() and ply:HasEquipmentItem(EQUIP_ARMOR) then
        dmginfo:ScaleDamage(0.7)
    end

    -- Players cant deal damage to each other before the round starts
    if IsPlayer(dmginfo:GetAttacker()) and GetRoundState() < ROUND_ACTIVE then
        dmginfo:ScaleDamage(0)
    end

    ply.was_headshot = false
    -- actual damage scaling
    if hitgroup == HITGROUP_HEAD then
        -- headshot if it was dealt by a bullet
        ply.was_headshot = dmginfo:IsBulletDamage()

        local wep = util.WeaponFromDamage(dmginfo)

        if IsValid(wep) and not GetConVar("ttt_disable_headshots"):GetBool() then
            local s = wep:GetHeadshotMultiplier(ply, dmginfo) or 2
            dmginfo:ScaleDamage(s)
        end
    elseif (hitgroup == HITGROUP_LEFTARM or
            hitgroup == HITGROUP_RIGHTARM or
            hitgroup == HITGROUP_LEFTLEG or
            hitgroup == HITGROUP_RIGHTLEG or
            hitgroup == HITGROUP_GEAR) then

        dmginfo:ScaleDamage(0.55)
    end

    -- Keep ignite-burn damage etc on old levels
    if (dmginfo:IsDamageType(DMG_DIRECT) or
            dmginfo:IsExplosionDamage() or
            dmginfo:IsDamageType(DMG_FALL) or
            dmginfo:IsDamageType(DMG_PHYSGUN)) then
        dmginfo:ScaleDamage(2)
    end
end

-- The GetFallDamage hook does not get called until around 600 speed, which is a
-- rather high drop already. Hence we do our own fall damage handling in
-- OnPlayerHitGround.
function GM:GetFallDamage(ply, speed)
    return 0
end

local fallsounds = {
    Sound("player/damage1.wav"),
    Sound("player/damage2.wav"),
    Sound("player/damage3.wav")
};

function GM:OnPlayerHitGround(ply, in_water, on_floater, speed)
    if ply:ShouldActLikeJester() and GetRoundState() == ROUND_ACTIVE then
        -- Jester team don't take fall damage
        return
    else
        if in_water or speed < 450 or not IsValid(ply) then return end

        -- Everything over a threshold hurts you, rising exponentially with speed
        local damage = math.pow(0.05 * (speed - 420), 1.75)

        -- I don't know exactly when on_floater is true, but it's probably when
        -- landing on something that is in water.
        if on_floater then damage = damage / 2 end

        -- if we fell on a dude, that hurts (him)
        local ground = ply:GetGroundEntity()
        if IsPlayer(ground) then
            if math.floor(damage) > 0 then
                local att = ply

                -- if the faller was pushed, that person should get attrib
                local push = ply.was_pushed
                if push then
                    if math.max(push.t or 0, push.hurt or 0) > CurTime() - 4 then
                        att = push.att
                    end
                end

                local dmg = DamageInfo()

                if att == ply then
                    -- hijack physgun damage as a marker of this type of kill
                    dmg:SetDamageType(DMG_CRUSH + DMG_PHYSGUN)
                else
                    -- if attributing to pusher, show more generic crush msg for now
                    dmg:SetDamageType(DMG_CRUSH)
                end

                dmg:SetAttacker(att)
                dmg:SetInflictor(att)
                dmg:SetDamageForce(Vector(0, 0, -1))
                dmg:SetDamage(damage)

                ground:TakeDamageInfo(dmg)
            end

            -- our own falling damage is cushioned
            damage = damage / 3
        end

        if math.floor(damage) > 0 then
            local dmg = DamageInfo()
            dmg:SetDamageType(DMG_FALL)
            dmg:SetAttacker(game.GetWorld())
            dmg:SetInflictor(game.GetWorld())
            dmg:SetDamageForce(Vector(0, 0, 1))
            dmg:SetDamage(damage)

            ply:TakeDamageInfo(dmg)

            -- play CS:S fall sound if we got somewhat significant damage
            if damage > 5 then
                sound.Play(table.Random(fallsounds), ply:GetShootPos(), 55 + math.Clamp(damage, 0, 50), 100)
            end
        end
    end
end

local ttt_postdm = CreateConVar("ttt_postround_dm", "0", FCVAR_NOTIFY)

function GM:AllowPVP()
    local rs = GetRoundState()
    return not (rs == ROUND_PREP or (rs == ROUND_POST and not ttt_postdm:GetBool()))
end

-- No damage during prep, etc
function GM:EntityTakeDamage(ent, dmginfo)
    if not IsValid(ent) then return end

    local att = dmginfo:GetAttacker()
    if GetRoundState() == ROUND_ACTIVE and ent:IsPlayer() then
        -- Block environmental damage to this jester-like player as long as it isn't a map trigger doing it
        -- Damage type DMG_GENERIC is "0" which doesn't seem to work with IsDamageType
        if ent:ShouldActLikeJester() and (not IsValid(att) or att:GetClass() ~= "trigger_hurt") and
              (dmginfo:IsExplosionDamage() or dmginfo:IsDamageType(DMG_BURN) or dmginfo:IsDamageType(DMG_CRUSH) or
               dmginfo:IsDamageType(DMG_DROWN) or dmginfo:GetDamageType() == 0 or dmginfo:IsDamageType(DMG_DISSOLVE)) then
            dmginfo:ScaleDamage(0)
            dmginfo:SetDamage(0)
        end

        -- Prevent damage from jesters
        if IsPlayer(att) and att:ShouldActLikeJester() then
            dmginfo:ScaleDamage(0)
            dmginfo:SetDamage(0)
        end
    end

    if not GAMEMODE:AllowPVP() then
        -- if player vs player damage, or if damage versus a prop, then zero
        if ent:IsExplosive() or (ent:IsPlayer() and IsPlayer(att)) then
            dmginfo:ScaleDamage(0)
            dmginfo:SetDamage(0)
        end
    elseif ent:IsPlayer() then
        GAMEMODE:PlayerTakeDamage(ent, dmginfo:GetInflictor(), att, dmginfo:GetDamage(), dmginfo)
    elseif ent:IsExplosive() then
        -- When a barrel hits a player, that player damages the barrel because
        -- Source physics. This gives stupid results like a player who gets hit
        -- with a barrel being blamed for killing himself or even their attacker.
        if IsPlayer(att) and
                dmginfo:IsDamageType(DMG_CRUSH) and
                IsValid(ent:GetPhysicsAttacker()) then

            dmginfo:SetAttacker(ent:GetPhysicsAttacker())
            dmginfo:ScaleDamage(0)
            dmginfo:SetDamage(0)
        end
    elseif ent.is_pinned and ent.OnPinnedDamage then
        ent:OnPinnedDamage(dmginfo)
        dmginfo:SetDamage(0)
    end
end

function GM:PlayerTakeDamage(ent, infl, att, amount, dmginfo)
    -- Change damage attribution if necessary
    if infl or att then
        local hurter, owner, owner_time

        -- fall back to the attacker if there is no inflictor
        if IsValid(infl) then
            hurter = infl
        elseif IsValid(att) then
            hurter = att
        end

        -- have a damage owner?
        if hurter and IsValid(hurter:GetDamageOwner()) then
            owner, owner_time = hurter:GetDamageOwner()

            -- barrel bangs can hurt us even if we threw them, but that's our fault
        elseif hurter and ent == hurter:GetPhysicsAttacker() and dmginfo:IsDamageType(DMG_BLAST) then
            owner = ent
        elseif hurter and hurter:IsVehicle() and IsValid(hurter:GetDriver()) then
            owner = hurter:GetDriver()
        end

        -- if we were hurt by a trap OR by a non-ply ent, and we were pushed
        -- recently, then our pusher is the attacker
        if owner_time or not IsPlayer(att) then
            local push = ent.was_pushed

            if push and IsValid(push.att) and push.t then
                -- push must be within the last 5 seconds, and must be done
                -- after the trap was enabled (if any)
                owner_time = owner_time or 0
                local t = math.max(push.t or 0, push.hurt or 0)
                if t > owner_time and t > CurTime() - 4 then
                    owner = push.att

                    -- pushed by a trap?
                    if IsValid(push.infl) then
                        dmginfo:SetInflictor(push.infl)
                    end

                    -- for slow-hurting traps we do leech-like damage timing
                    push.hurt = CurTime()
                end
            end
        end

        -- if we are being hurt by a physics object, we will take damage from
        -- the world entity as well, which screws with damage attribution so we
        -- need to detect and work around that
        if IsValid(owner) and dmginfo:IsDamageType(DMG_CRUSH) then
            -- we should be able to use the push system for this, as the cases are
            -- similar: event causes future damage but should still be attributed
            -- physics traps can also push you to your death, for example
            local push = ent.was_pushed or {}

            -- if we already blamed this on a pusher, no need to do more
            -- else we override whatever was in was_pushed with info pointing
            -- at our damage owner
            if push.att ~= owner then
                owner_time = owner_time or CurTime()

                push.att = owner
                push.t = owner_time
                push.hurt = CurTime()

                -- store the current inflictor so that we can attribute it as the
                -- trap used by the player in the event
                if IsValid(infl) then
                    push.infl = infl
                end

                -- make sure this is set, for if we created a new table
                ent.was_pushed = push
            end
        end

        -- make the owner of the damage the attacker
        att = IsValid(owner) and owner or att
        dmginfo:SetAttacker(att)
    end

    -- scale phys damage caused by props
    if dmginfo:IsDamageType(DMG_CRUSH) and IsValid(att) then

        -- player falling on player, or player hurt by prop?
        if not dmginfo:IsDamageType(DMG_PHYSGUN) then

            -- this is prop-based physics damage
            dmginfo:ScaleDamage(0.25)

            -- if the prop is held, no damage
            if IsValid(infl) and IsPlayer(infl:GetOwner()) then
                dmginfo:ScaleDamage(0)
                dmginfo:SetDamage(0)
            end
        end
    end

    -- Get the active entity fire info
    local ignite_info = ent.ignite_info

    -- Check if we have extended info
    if ent.ignite_info_ext then
        -- If we have extended info but not regular info
        if not ignite_info then
            -- Check that the extended info is still valid and use it, if so
            if ent.ignite_info_ext.end_time > CurTime() then
                ignite_info = ent.ignite_info_ext
            -- Otherwise clear it out
            else
                ent.ignite_info_ext = nil
            end
        else
            -- If we have both regular and extended info, save the attacker and inflictor to the extended info for later
            if not ent.ignite_info_ext.att then
                ent.ignite_info_ext.att = ent.ignite_info.att
            end
            if not ent.ignite_info_ext.infl then
                ent.ignite_info_ext.infl = ent.ignite_info.infl
            end
        end
    end

    -- Handle fire attacker
    if ignite_info and dmginfo:IsDamageType(DMG_DIRECT) then
        local datt = dmginfo:GetAttacker()
        if not IsPlayer(datt) and IsValid(ignite_info.att) and IsValid(ignite_info.infl) then
            dmginfo:SetAttacker(ignite_info.att)
            dmginfo:SetInflictor(ignite_info.infl)

            -- Set burning damage from jester team to zero, regardless of source
            if ignite_info.att:ShouldActLikeJester() then
                dmginfo:ScaleDamage(0)
                dmginfo:SetDamage(0)
            end
        end
    end

    -- try to work out if this was push-induced leech-water damage (common on
    -- some popular maps like dm_island17)
    if ent.was_pushed and ent == att and dmginfo:GetDamageType() == DMG_GENERIC and util.BitSet(util.PointContents(dmginfo:GetDamagePosition()), CONTENTS_WATER) then
        local t = math.max(ent.was_pushed.t or 0, ent.was_pushed.hurt or 0)
        if t > CurTime() - 3 then
            dmginfo:SetAttacker(ent.was_pushed.att)
            ent.was_pushed.hurt = CurTime()
        end
    end

    -- start painting blood decals
    util.StartBleeding(ent, dmginfo:GetDamage(), 5)

    -- general actions for pvp damage
    if ent ~= att and IsPlayer(att) and GetRoundState() == ROUND_ACTIVE and math.floor(dmginfo:GetDamage()) > 0 then
        -- scale everything to karma damage factor except the knife, because it
        -- assumes a kill
        if not dmginfo:IsDamageType(DMG_SLASH) then
            dmginfo:ScaleDamage(att:GetDamageFactor())
        end

        -- process the effects of the damage on karma
        KARMA.Hurt(att, ent, dmginfo)

        if GetConVar("ttt_debug_logkills"):GetBool() then
            DamageLog(Format("DMG: \t %s [%s] damaged %s [%s] for %d dmg", att:Nick(), ROLE_STRINGS[att:GetRole()], ent:Nick(), ROLE_STRINGS[ent:GetRole()], math.Round(dmginfo:GetDamage())))
        end
    end
end

function GM:OnNPCKilled() end

-- Drowning and such
function GM:Tick()
    -- three cheers for micro-optimizations
    local plys = GetAllPlayers()
    local tm
    local ply
    for i = 1, #plys do
        ply = plys[i]
        tm = ply:Team()
        if tm == TEAM_TERROR and ply:Alive() then
            -- Drowning
            if ply:WaterLevel() == 3 then
                if ply:IsOnFire() then
                    ply:Extinguish()
                    ply.ignite_info = nil
                end

                if ply.drowning then
                    if ply.drowning < CurTime() then
                        local dmginfo = DamageInfo()
                        dmginfo:SetDamage(15)
                        dmginfo:SetDamageType(DMG_DROWN)
                        dmginfo:SetAttacker(game.GetWorld())
                        dmginfo:SetInflictor(game.GetWorld())
                        dmginfo:SetDamageForce(Vector(0, 0, 1))

                        ply:TakeDamageInfo(dmginfo)

                        -- have started drowning properly
                        ply.drowning = CurTime() + 1
                    end
                -- Don't let roles who shouldn't drown start taking drowning damage
                elseif not ply:ShouldNotDrown() then
                    -- will start drowning soon
                    ply.drowning = CurTime() + 8
                end
            else
                ply.drowning = nil
            end

            -- Run DNA Scanner think also when it is not deployed
            if IsValid(ply.scanner_weapon) and ply:GetActiveWeapon() ~= ply.scanner_weapon then
                ply.scanner_weapon:Think()
            end

            CallHook("TTTPlayerAliveThink", nil, ply)
        elseif tm == TEAM_SPEC then
            if ply.propspec then
                PROPSPEC.Recharge(ply)

                if IsValid(ply:GetObserverTarget()) then
                    ply:SetPos(ply:GetObserverTarget():GetPos())
                end
            end

            -- if spectators are alive, ie. they picked spectator mode, then
            -- DeathThink doesn't run, so we have to SpecThink here
            if ply:Alive() then
                self:SpectatorThink(ply)
            end
        end
    end
end

function GM:ShowHelp(ply)
    if IsValid(ply) then
        ply:ConCommand("ttt_helpscreen")
    end
end

function GM:PlayerRequestTeam(ply, teamid)
end

-- Implementing stuff that should already be in gmod, chpt. 389
function GM:PlayerEnteredVehicle(ply, vehicle, role)
    if IsValid(vehicle) then
        vehicle:SetNWEntity("ttt_driver", ply)
    end
end

function GM:PlayerLeaveVehicle(ply, vehicle)
    if IsValid(vehicle) then
        -- setting nil will not do anything, so bogusify
        vehicle:SetNWEntity("ttt_driver", vehicle)
    end
end

function GM:AllowPlayerPickup(ply, obj)
    return false
end

function GM:PlayerShouldTaunt(ply, actid)
    -- Disable taunts, we don't have a system for them (camera freezing etc).
    -- Mods/plugins that add such a system should override this.
    return false
end

local function GetTargetPlayerByName(name, allow_dead)
    name = string.lower(name)
    for _, v in RandomPairs(GetAllPlayers()) do
        if IsValid(v) and (allow_dead or v:IsActive()) and string.lower(v:Nick()) == name then
            return v
        end
    end
end

local function GetRandomTargetPlayer(ply, allow_dead)
    for _, v in RandomPairs(GetAllPlayers()) do
        if IsValid(v) and (allow_dead or v:IsActive()) and v ~= ply and not v:ShouldActLikeJester() then
            return v
        end
    end
end

local function PlayerAutoComplete(cmd, args)
    -- Split all the arguments out so we can keep track of them
    local arg_split = {}
    for _, v in ipairs(string.Explode("\"", args, false)) do
        local trimmed = string.Trim(v)
        if #trimmed > 0 then
            table.insert(arg_split, trimmed)
        end
    end

    -- Clean up the current and all previous arguments
    local name = ""
    local other_args = ""
    if not table.IsEmpty(arg_split) then
        name = string.Trim(string.lower(arg_split[#arg_split]))
        if #arg_split > 1 then
            other_args = " \"" .. table.concat(arg_split, "\" \"", 1, #arg_split - 1) .. "\""
        end
    end

    -- Find player options that match the given value (or all if there is no given value)
    local options = {}
    for _, v in ipairs(GetAllPlayers()) do
        if #name == 0 or string.find(string.lower(v:Nick()), name) then
            table.insert(options, cmd .. other_args .. " \"" .. v:Nick() .. "\"")
        end
    end
    return options
end

local function KillFromPlayer(victim, killer, remove_body)
    if not IsValid(victim) or not victim:Alive() then return end
    if not IsValid(killer) then return end

    print("Killing " .. victim:Nick() .. " by " .. killer:Nick())

    -- Kill the player with a "bullet"
    local dmginfo = DamageInfo()
    dmginfo:SetDamage(1000)
    dmginfo:SetAttacker(killer)
    dmginfo:SetInflictor(killer)
    dmginfo:SetDamageType(DMG_BULLET)
    victim:TakeDamageInfo(dmginfo)

    if remove_body then
        timer.Simple(0.25, function()
            local body = victim.server_ragdoll or victim:GetRagdollEntity()
            if IsValid(body) then
                print("and removing body")
                body:Remove()
            end
        end)
    end
end

concommand.Add("ttt_kill_from_random", function(ply, cmd, args)
    if not IsValid(ply) or not ply:Alive() then return end

    local remove_body = #args > 0 and tobool(args[1])
    local allow_dead = #args > 1 and tobool(args[2])
    local killer = GetRandomTargetPlayer(ply, allow_dead)
    KillFromPlayer(ply, killer, remove_body)
end, PlayerAutoComplete, "Kills the local player from a random target", FCVAR_CHEAT)

concommand.Add("ttt_kill_from_player", function(ply, cmd, args)
    if not IsValid(ply) or not ply:Alive() then return end
    if #args < 1 then return end

    local killer_name = args[1]
    local allow_dead = #args > 2 and tobool(args[3])
    local killer = GetTargetPlayerByName(killer_name, allow_dead)
    if not IsPlayer(killer) then
        print("No player named " .. killer_name .. " found")
        return
    end

    local remove_body = #args > 1 and tobool(args[2])
    KillFromPlayer(ply, killer, remove_body)
end, PlayerAutoComplete, "Kills the local player from a specific target", FCVAR_CHEAT)

concommand.Add("ttt_kill_target_from_random", function(ply, cmd, args)
    if #args < 1 then return end

    local victim_name = args[1]
    local victim = GetTargetPlayerByName(victim_name)
    if not IsPlayer(victim) then
        print("No player named " .. victim_name .. " found")
        return
    end

    local remove_body = #args > 1 and tobool(args[2])
    local allow_dead = #args > 2 and tobool(args[3])
    local killer = GetRandomTargetPlayer(victim, allow_dead)
    KillFromPlayer(victim, killer, remove_body)
end, PlayerAutoComplete, "Kills a target from a random target", FCVAR_CHEAT)

concommand.Add("ttt_kill_target_from_player", function(ply, cmd, args)
    if #args < 2 then return end

    local victim_name = args[1]
    local victim = GetTargetPlayerByName(victim_name)
    if not IsPlayer(victim) then
        print("No player named " .. victim_name .. " found")
        return
    end

    local killer_name = args[2]
    local allow_dead = #args > 3 and tobool(args[4])
    local killer = GetTargetPlayerByName(killer_name, allow_dead)
    if not IsPlayer(killer) then
        print("No player named " .. killer_name .. " found")
        return
    end

    local remove_body = #args > 2 and tobool(args[3])
    KillFromPlayer(victim, killer, remove_body)
end, PlayerAutoComplete, "Kills a target from another target", FCVAR_CHEAT)

local function DamageFromPlayer(victim, attacker, damage)
    if not IsValid(victim) or not victim:Alive() then return end
    if not IsValid(attacker) then return end

    print("Damaging " .. victim:Nick() .. " from " .. attacker:Nick())

    -- Damage the player with a "bullet"
    local dmginfo = DamageInfo()
    dmginfo:SetDamage(damage or 1)
    dmginfo:SetAttacker(attacker)
    dmginfo:SetInflictor(attacker)
    dmginfo:SetDamageType(DMG_BULLET)
    dmginfo:SetDamagePosition(attacker:GetPos())
    victim:TakeDamageInfo(dmginfo)
end

concommand.Add("ttt_damage_from_random", function(ply, cmd, args)
    if not IsValid(ply) or not ply:Alive() then return end

    local allow_dead = #args > 1 and tobool(args[2])
    local attacker = GetRandomTargetPlayer(ply, allow_dead)
    local damage = #args > 0 and tonumber(args[1])
    DamageFromPlayer(ply, attacker, damage)
end, PlayerAutoComplete, "Damages the local player from a random target", FCVAR_CHEAT)

concommand.Add("ttt_damage_from_player", function(ply, cmd, args)
    if not IsValid(ply) or not ply:Alive() then return end
    if #args < 1 then return end

    local attacker_name = args[1]
    local allow_dead = #args > 2 and tobool(args[3])
    local attacker = GetTargetPlayerByName(attacker_name, allow_dead)
    if not IsPlayer(attacker) then
        print("No player named " .. attacker_name .. " found")
        return
    end

    local damage = #args > 1 and tonumber(args[2])
    DamageFromPlayer(ply, attacker, damage)
end, PlayerAutoComplete, "Damages the local player from a specific target", FCVAR_CHEAT)

concommand.Add("ttt_damage_target_from_random", function(ply, cmd, args)
    if #args < 1 then return end

    local victim_name = args[1]
    local victim = GetTargetPlayerByName(victim_name)
    if not IsPlayer(victim) then
        print("No player named " .. victim_name .. " found")
        return
    end

    local damage = #args > 1 and tonumber(args[2])
    local allow_dead = #args > 2 and tobool(args[3])
    local attacker = GetRandomTargetPlayer(victim, allow_dead)
    DamageFromPlayer(victim, attacker, damage)
end, PlayerAutoComplete, "Damages a target from a random target", FCVAR_CHEAT)

concommand.Add("ttt_damage_target_from_player", function(ply, cmd, args)
    if #args < 2 then return end

    local victim_name = args[1]
    local victim = GetTargetPlayerByName(victim_name)
    if not IsPlayer(victim) then
        print("No player named " .. victim_name .. " found")
        return
    end

    local attacker_name = args[2]
    local allow_dead = #args > 3 and tobool(args[4])
    local attacker = GetTargetPlayerByName(attacker_name, allow_dead)
    if not IsPlayer(attacker) then
        print("No player named " .. attacker_name .. " found")
        return
    end

    local damage = #args > 2 and tonumber(args[3])
    DamageFromPlayer(victim, attacker, damage)
end, PlayerAutoComplete, "Damages a target from another target", FCVAR_CHEAT)