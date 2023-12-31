AddCSLuaFile()

local table = table

-- Initialize role features
ROLE_CAN_SEE_JESTERS[ROLE_MADSCIENTIST] = true
ROLE_CAN_SEE_MIA[ROLE_MADSCIENTIST] = true

------------------
-- ROLE CONVARS --
------------------

CreateConVar("ttt_madscientist_respawn_enabled", "0", FCVAR_REPLICATED)
local madscientist_is_monster = CreateConVar("ttt_madscientist_is_monster", "0", FCVAR_REPLICATED)

ROLE_CONVARS[ROLE_MADSCIENTIST] = {}
table.insert(ROLE_CONVARS[ROLE_MADSCIENTIST], {
    cvar = "ttt_madscientist_device_time",
    type = ROLE_CONVAR_TYPE_NUM,
    decimal = 0
})
table.insert(ROLE_CONVARS[ROLE_MADSCIENTIST], {
    cvar = "ttt_madscientist_respawn_enabled",
    type = ROLE_CONVAR_TYPE_BOOL
})
table.insert(ROLE_CONVARS[ROLE_MADSCIENTIST], {
    cvar = "ttt_madscientist_is_monster",
    type = ROLE_CONVAR_TYPE_BOOL
})
table.insert(ROLE_CONVARS[ROLE_MADSCIENTIST], {
    cvar = "ttt_madscientist_can_see_jesters",
    type = ROLE_CONVAR_TYPE_BOOL
})
table.insert(ROLE_CONVARS[ROLE_MADSCIENTIST], {
    cvar = "ttt_madscientist_update_scoreboard",
    type = ROLE_CONVAR_TYPE_BOOL
})

-------------------
-- ROLE FEATURES --
-------------------

ROLE_SELECTION_PREDICATE[ROLE_MADSCIENTIST] = function()
    -- Mad Scientist can only spawn when zombies are on their team
    return (INDEPENDENT_ROLES[ROLE_MADSCIENTIST] and INDEPENDENT_ROLES[ROLE_ZOMBIE]) or
            (MONSTER_ROLES[ROLE_MADSCIENTIST] and MONSTER_ROLES[ROLE_ZOMBIE])
end

hook.Add("TTTUpdateRoleState", "MadScientist_Team_TTTUpdateRoleState", function()
    local is_monster = madscientist_is_monster:GetBool()
    MONSTER_ROLES[ROLE_MADSCIENTIST] = is_monster
    INDEPENDENT_ROLES[ROLE_MADSCIENTIST] = not is_monster
end)