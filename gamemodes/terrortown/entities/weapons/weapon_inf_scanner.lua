AddCSLuaFile()

local IsValid = IsValid
local math = math
local pairs = pairs
local player = player
local surface = surface
local string = string

DEFINE_BASECLASS "weapon_tttbase"

SWEP.HoldType               = "normal"

if SERVER then
    resource.AddFile("models/weapons/v_binoculars.mdl")
    resource.AddFile("models/weapons/w_binoculars.mdl")
    resource.AddFile("materials/models/weapons/v_binoculars/binocular2.vmt")
end

if CLIENT then
   SWEP.PrintName           = "Scanner"
   SWEP.Slot                = 8

   SWEP.ViewModelFOV        = 10
   SWEP.ViewModelFlip       = false
   SWEP.DrawCrosshair       = false

   SWEP.EquipMenuData = {
      type  = "item_weapon",
      desc  = "binoc_desc"
   };

   SWEP.Icon                = "vgui/ttt/icon_binoc"
end

SWEP.Base                   = "weapon_tttbase"
SWEP.Category = WEAPON_CATEGORY_ROLE

SWEP.ViewModel		        = "models/weapons/v_binoculars.mdl"
SWEP.WorldModel		        = "models/weapons/w_binoculars.mdl"

SWEP.Primary.ClipSize       = -1
SWEP.Primary.DefaultClip    = -1
SWEP.Primary.Automatic      = false
SWEP.Primary.Ammo           = "none"
SWEP.Primary.Delay          = 0

SWEP.Secondary.ClipSize     = -1
SWEP.Secondary.DefaultClip  = -1
SWEP.Secondary.Automatic    = true
SWEP.Secondary.Ammo         = "none"
SWEP.Secondary.Delay        = 0

SWEP.Kind                   = WEAPON_ROLE

SWEP.InLoadoutFor = {ROLE_INFORMANT}

SWEP.AllowDrop              = false

SWEP.WorldModelAttachment  = "ValveBiped.Bip01_R_Hand"
SWEP.WorldModelVector      = Vector(5, -5, 0)
SWEP.WorldModelAngle       = Angle(180, 180, 0)
SWEP.ViewModelDistance     = 100

local SCANNER_IDLE = 0
local SCANNER_LOCKED = 1
local SCANNER_SEARCHING = 2
local SCANNER_LOST = 3

if SERVER then
    CreateConVar("ttt_informant_scanner_time", "5", FCVAR_NONE, "The amount of time (in seconds) the informant's scanner takes to use", 0, 60)
    CreateConVar("ttt_informant_scanner_float_time", "1", FCVAR_NONE, "The amount of time (in seconds) it takes for the informant's scanner to lose it's target without line of sight", 0, 60)
    CreateConVar("ttt_informant_scanner_cooldown", "3", FCVAR_NONE, "The amount of time (in seconds) the informant's tracker goes on cooldown for after losing it's target", 0, 60)
end

function SWEP:SetupDataTables()
    self:NetworkVar("Int", 0, "State")
    self:NetworkVar("Int", 1, "ScanTime")
    self:NetworkVar("String", 0, "Target")
    self:NetworkVar("String", 1, "Message")
    self:NetworkVar("Float", 0, "ScanStart")
    self:NetworkVar("Float", 1, "TargetLost")
    self:NetworkVar("Float", 2, "Cooldown")

    if SERVER then
        self:SetScanTime(GetConVar("ttt_informant_scanner_time"):GetInt())
    end
end

function SWEP:PrimaryAttack()
end

function SWEP:SecondaryAttack()
end

function SWEP:GetViewModelPosition(pos, ang)
	local forward = ang:Forward()
    -- Move the model away from the player camera so it doesn't take up half the screen
    local dist = Vector(-forward.x * self.ViewModelDistance, -forward.y * self.ViewModelDistance, -forward.z * self.ViewModelDistance)
	return pos - dist, ang
end

function SWEP:Deploy()
    if SERVER and IsValid(self:GetOwner()) then
        self:GetOwner():DrawViewModel(false)
    end

    self:DrawShadow(false)

    return true
end

if SERVER then
    function SWEP:IsTargetingPlayer()
        local tr = self:GetOwner():GetEyeTrace(MASK_SHOT)
        local ent = tr.Entity

        return (IsValid(ent) and ent:IsPlayer() and ent:IsActive()) and ent or false
    end

    function SWEP:Scan(target)
        if target:IsActive() then
            local stage = target:GetNWInt("TTTInformantScanStage", 0)
            if target:IsDetectiveTeam() and stage == INFORMANT_UNSCANNED then
                if GetConVar("ttt_detective_hide_special_mode"):GetInt() >= 1 then
                    stage = INFORMANT_SCANNED_TEAM
                else
                    stage = INFORMANT_SCANNED_ROLE
                end
                target:SetNWInt("TTTInformantScanStage", stage)
            elseif target:IsJesterTeam() then
                if GetConVar("ttt_informant_can_scan_jesters"):GetBool() then
                    if stage == INFORMANT_UNSCANNED then
                        target:SetNWInt("TTTInformantScanStage", INFORMANT_SCANNED_TEAM)
                    end
                else
                    self:SetState(SCANNER_IDLE)
                    self:SetTarget("")
                    self:SetScanStart(-1)
                    self:SetMessage("")
                    return false
                end
            elseif target:IsTraitorTeam() then
                if GetConVar("ttt_informant_can_scan_glitches"):GetBool() then
                    local glitchMode = GetConVar("ttt_glitch_mode"):GetInt()
                    if ((glitchMode == GLITCH_SHOW_AS_TRAITOR and target:IsTraitor()) or glitchMode >= GLITCH_SHOW_AS_SPECIAL_TRAITOR) and stage == INFORMANT_UNSCANNED then
                        target:SetNWInt("TTTInformantScanStage", INFORMANT_SCANNED_TEAM)
                    else
                        self:SetState(SCANNER_IDLE)
                        self:SetTarget("")
                        self:SetScanStart(-1)
                        self:SetMessage("")
                        return false
                    end
                else
                    self:SetState(SCANNER_IDLE)
                    self:SetTarget("")
                    self:SetScanStart(-1)
                    self:SetMessage("")
                    return false
                end
            elseif target:IsGlitch() then
                if GetConVar("ttt_informant_can_scan_glitches"):GetBool() and stage == INFORMANT_UNSCANNED then
                    target:SetNWInt("TTTInformantScanStage", INFORMANT_SCANNED_TEAM)
                else
                    self:SetState(SCANNER_IDLE)
                    self:SetTarget("")
                    self:SetScanStart(-1)
                    self:SetMessage("")
                    return false
                end
            end

            local share = GetGlobalBool("ttt_informant_share_scans", true)
            if CurTime() - self:GetScanStart() >= GetConVar("ttt_informant_scanner_time"):GetInt() then
                stage = stage + 1
                local owner = self:GetOwner()
                if stage == INFORMANT_SCANNED_TEAM then
                    local message = " discovered that " .. target:Nick() .. " is "
                    if target:IsInnocentTeam() then
                        message = message .. "an innocent role."
                    elseif target:IsIndependentTeam() then
                        message = message .. "an independent role."
                    elseif target:IsMonsterTeam() then
                        message = message .. "a monster role."
                    end
                    owner:PrintMessage(HUD_PRINTTALK, "You have" .. message)
                    if share then
                        for _, p in pairs(GetAllPlayers()) do
                            if p:IsActiveTraitorTeam() and not p:IsInformant() then
                                p:PrintMessage(HUD_PRINTTALK, "The informant has " .. message)
                            end
                        end
                    end
                elseif stage == INFORMANT_SCANNED_ROLE then
                    owner:PrintMessage(HUD_PRINTTALK,  "You have discovered that " .. target:Nick() .. " is " .. ROLE_STRINGS_EXT[target:GetRole()] .. ".")
                    if share then
                        for _, p in pairs(GetAllPlayers()) do
                            if p:IsActiveTraitorTeam() and not p:IsInformant() then
                                p:PrintMessage(HUD_PRINTTALK,  "The informant has discovered that " .. target:Nick() .. " is " .. ROLE_STRINGS_EXT[target:GetRole()] .. ".")
                            end
                        end
                    end
                elseif stage == INFORMANT_SCANNED_TRACKED then
                    owner:PrintMessage(HUD_PRINTTALK, "You have tracked the movements of " .. target:Nick() .. " (" .. ROLE_STRINGS[target:GetRole()] .. ").")
                    if share then
                        for _, p in pairs(GetAllPlayers()) do
                            if p:IsActiveTraitorTeam() and not p:IsInformant() then
                                p:PrintMessage(HUD_PRINTTALK, "The informant has tracked the movements of " .. target:Nick() .. " (" .. ROLE_STRINGS[target:GetRole()] .. ").")
                            end
                        end
                    end
                end
                self:SetState(SCANNER_IDLE)
                self:SetTarget("")
                self:SetScanStart(-1)
                self:SetMessage("")
                target:SetNWInt("TTTInformantScanStage", stage)
            end
        else
            self:SetState(SCANNER_LOST)
            self:SetTarget("")
            self:SetScanStart(-1)
            self:SetCooldown(CurTime())
            self:SetMessage("TARGET LOST")
        end
    end

    function SWEP:Think()
        local state = self:GetState()
        if state == SCANNER_IDLE then
            local target = self:IsTargetingPlayer()
            if target then
                if target:GetNWInt("TTTInformantScanStage", 0) < INFORMANT_SCANNED_TRACKED then
                    self:SetState(SCANNER_LOCKED)
                    self:SetTarget(target:SteamID64())
                    self:SetScanStart(CurTime())
                    self:SetMessage("SCANNING " .. string.upper(target:Nick()))
                end
            end
        elseif state == SCANNER_LOCKED then
            local target = player.GetBySteamID64(self:GetTarget())
            if target:IsActive() then
                if self:GetOwner():IsLineOfSightClear(target) then
                    self:Scan(target)
                else
                    self:SetState(SCANNER_SEARCHING)
                    self:SetTargetLost(CurTime())
                    self:SetMessage("SCANNING " .. string.upper(target:Nick()) .. "(LOSING TARGET)")
                end
            else
                self:SetState(SCANNER_LOST)
                self:SetTarget("")
                self:SetScanStart(-1)
                self:SetCooldown(CurTime())
                self:SetMessage("TARGET LOST")
            end
        elseif state == SCANNER_SEARCHING then
            local target = player.GetBySteamID64(self:GetTarget())
            if target:IsActive() then
                if CurTime() - self:GetTargetLost() >= GetConVar("ttt_informant_scanner_float_time"):GetInt() then
                    self:SetState(SCANNER_LOST)
                    self:SetTarget("")
                    self:SetScanStart(-1)
                    self:SetCooldown(CurTime())
                    self:SetMessage("TARGET LOST")
                elseif self:GetOwner():IsLineOfSightClear(target) then
                    self:SetState(SCANNER_LOCKED)
                    self:SetTargetLost(-1)
                    self:SetMessage("SCANNING " .. string.upper(target:Nick()))
                    self:Scan(target)
                else
                    self:Scan(target)
                end
            else
                self:SetState(SCANNER_LOST)
                self:SetTarget("")
                self:SetScanStart(-1)
                self:SetCooldown(CurTime())
                self:SetMessage("TARGET LOST")
            end
        elseif state == SCANNER_LOST then
            if CurTime() - self:GetCooldown() >= GetConVar("ttt_informant_scanner_cooldown"):GetInt() then
                self:SetState(SCANNER_IDLE)
                self:SetCooldown(-1)
                self:SetMessage("")
            end
        end
    end
end

if CLIENT then
    function SWEP:Initialize()
        self:AddHUDHelp("Look at a player to start scanning", "Keep light of sight or you will lose your target", false)

        return self.BaseClass.Initialize(self)
    end

    local T = LANG.GetTranslation
    function SWEP:DrawHUD()
        local state = self:GetState()
        self.BaseClass.DrawHUD(self)

        if state == SCANNER_IDLE then return end

        local scan = self:GetScanTime()
        local time = self:GetScanStart() + scan

        local x = ScrW() / 2.0
        local y = ScrH() / 2.0

        y = y + (y / 3)

        local w, h = 100, 20
        local m = 10

        if state == SCANNER_LOCKED or state == SCANNER_SEARCHING then
            if time < 0 then return end

            local cc = math.min(1, 1 - ((time - CurTime()) / scan))

            if state == SCANNER_LOCKED then
                surface.SetDrawColor(0, 255, 0, 155)
            else
                surface.SetDrawColor(255, 255, 0, 155)
            end

            surface.DrawOutlinedRect(x - m - (3 * w) / 2, y - h, w, h)
            surface.DrawOutlinedRect(x - w / 2, y - h, w, h)
            surface.DrawOutlinedRect(x + m + w / 2, y - h, w, h)

            local target = player.GetBySteamID64(self:GetTarget())
            local targetState = target:GetNWInt("TTTInformantScanStage", 0)

            if targetState == INFORMANT_UNSCANNED then
                surface.DrawRect(x - m - (3 * w) / 2, y - h, w * cc, h)
            elseif targetState == INFORMANT_SCANNED_TEAM then
                surface.DrawRect(x - m - (3 * w) / 2, y - h, w, h)
                surface.DrawRect(x - w / 2, y - h, w * cc, h)
            elseif targetState == INFORMANT_SCANNED_ROLE then
                surface.DrawRect(x - m - (3 * w) / 2, y - h, w, h)
                surface.DrawRect(x - w / 2, y - h, w, h)
                surface.DrawRect(x + m + w / 2, y - h, w * cc, h)
            end

            surface.SetFont("TabLarge")
            surface.SetTextColor(255, 255, 255, 180)
            surface.SetTextPos((x - m - (3 * w) / 2) + 3, y - h - 15)
            surface.DrawText(self:GetMessage())
        elseif state == SCANNER_LOST then
            surface.SetDrawColor(200 + math.sin(CurTime() * 32) * 50, 0, 0, 155)

            surface.DrawOutlinedRect(x - m - (3 * w) / 2, y - h, w, h)
            surface.DrawOutlinedRect(x - w / 2, y - h, w, h)
            surface.DrawOutlinedRect(x + m + w / 2, y - h, w, h)

            surface.DrawRect(x - m - (3 * w) / 2, y - h, w, h)
            surface.DrawRect(x - w / 2, y - h, w, h)
            surface.DrawRect(x + m + w / 2, y - h, w, h)

            surface.SetFont("TabLarge")
            surface.SetTextColor(255, 255, 255, 180)
            surface.SetTextPos((x - m - (3 * w) / 2) + 3, y - h - 15)
            surface.DrawText(self:GetMessage())
        end
    end

    function SWEP:DrawWorldModel()
    end
end
