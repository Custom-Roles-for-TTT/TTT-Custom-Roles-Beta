AddCSLuaFile()

ROLE_STARTING_HEALTH[ROLE_LOOTGOBLIN] = 50
ROLE_MAX_HEALTH[ROLE_LOOTGOBLIN] = 50
ROLE_STARTING_CREDITS[ROLE_LOOTGOBLIN] = 3
ROLE_IS_ACTIVE[ROLE_LOOTGOBLIN] = function(ply)
    if ply:IsLootGoblin() then return ply:GetNWBool("LootGoblinActive", false) end
end