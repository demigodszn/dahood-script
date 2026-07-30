-- =============================================
-- MODE SELECTION — must run first
-- =============================================
getgenv().CamlockTarget = nil
getgenv().ScriptMode = nil  -- always re-prompt; getgenv() persistence was causing stale "PC" mode

if not getgenv().ScriptMode then
    local StarterGui = game:GetService("StarterGui")
    local LocalPlayer = game:GetService("Players").LocalPlayer

    local modeGui = Instance.new("ScreenGui")
    modeGui.Name = "ModeSelectGui"
    modeGui.ResetOnSpawn = false
    modeGui.IgnoreGuiInset = true
    modeGui.Parent = LocalPlayer.PlayerGui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 220, 0, 130)
    frame.Position = UDim2.new(0.5, -110, 0.5, -65)
    frame.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
    frame.Parent = modeGui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 30)
    label.BackgroundTransparency = 1
    label.Text = "Select Mode"
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 16
    label.Parent = frame

    local pcBtn = Instance.new("TextButton")
    pcBtn.Size = UDim2.new(1, -20, 0, 36)
    pcBtn.Position = UDim2.new(0, 10, 0, 36)
    pcBtn.BackgroundColor3 = Color3.fromRGB(90, 80, 130)
    pcBtn.Text = "PC Mode"
    pcBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    pcBtn.Font = Enum.Font.GothamBold
    pcBtn.TextSize = 14
    pcBtn.Parent = frame
    Instance.new("UICorner", pcBtn).CornerRadius = UDim.new(0, 6)

    local mobileBtn = Instance.new("TextButton")
    mobileBtn.Size = UDim2.new(1, -20, 0, 36)
    mobileBtn.Position = UDim2.new(0, 10, 0, 80)
    mobileBtn.BackgroundColor3 = Color3.fromRGB(90, 80, 130)
    mobileBtn.Text = "Mobile Mode"
    mobileBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    mobileBtn.Font = Enum.Font.GothamBold
    mobileBtn.TextSize = 14
    mobileBtn.Parent = frame
    Instance.new("UICorner", mobileBtn).CornerRadius = UDim.new(0, 6)

    local chosen = nil
    pcBtn.MouseButton1Click:Connect(function() chosen = "PC" end)
    mobileBtn.MouseButton1Click:Connect(function() chosen = "Mobile" end)

    while not chosen do task.wait(0.1) end
    getgenv().ScriptMode = chosen
    modeGui:Destroy()
end

local IS_MOBILE = getgenv().ScriptMode == "Mobile"

-- =============================================
-- CORE STATE
-- =============================================
getgenv().HitboxSize = Vector3.new(9, 9, 9)
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().WallCheckEnabled = true
getgenv().Whitelist = getgenv().Whitelist or {}
getgenv().AutoLockPool = getgenv().AutoLockPool or {}
getgenv().AutoLockEnabled = false
getgenv().SafeMode = false
-- MobileMouseLockEnabled removed — mobile mouse lock excised entirely
-- MC (Mouse Camlock) — PC only. M key toggles. Left-click acquires target under cursor.
getgenv().MouseCamlockEnabled = false

-- Ordered R16 body-scan sequence — anatomically adjacent entries so
-- every transition is a short spatial hop, never a full-body teleport.
-- Pattern: head → left arm sweep down → center torso → right arm sweep up →
--          left leg sweep down → right leg sweep up → back to head.
local CYCLE_PART_POOL = {
    "Head",
    "UpperTorso",
    "LeftUpperArm",
    "LeftLowerArm",
    "LeftHand",
    "LowerTorso",
    "HumanoidRootPart",
    "RightHand",
    "RightLowerArm",
    "RightUpperArm",
    "LeftUpperLeg",
    "LeftLowerLeg",
    "LeftFoot",
    "RightFoot",
    "RightLowerLeg",
    "RightUpperLeg",
}

local KNOCK_THRESHOLD = 2
local RELOCK_THRESHOLD = 11
local LOCAL_HEALTH_GATE = 15
local MAX_HEALTH = 100
local TRIPLE_PRESS_WINDOW = 1.0

local VELOCITY_SMOOTH_RATE = 8.0
local LOOK_SMOOTH_RATE = 16.0
local LOOK_JITTER_MAG = 0.015
local LEAD_TIME = 0.12
local JUMP_VEL_THRESHOLD = 18
local JUMP_SNAP_RATE = 26.0 * 0.95
local JUMP_SNAP_DURATION = 0.35
local PART_CYCLE_INTERVAL      = 0.35  -- time per part in the body-scan cycle (16 parts → ~5.6s full loop)
local PART_TRANSITION_DURATION = 0.12  -- smoothstep blend duration between consecutive parts

local MACRO_SPEED_MULT = 1.15
local CFRAME_ACCEL_SPIKE = 500
local CFRAME_TRACK_RATE_MULT = 1.6
local FLYING_TRACK_RATE_MULT = 2.1
local SPEEDHACK_VEL_THRESHOLD = 60
local FLYING_Y_VEL_THRESHOLD = 25

local MISS_CHANCE_PER_SECOND = 0.01
local MISS_OFFSET_MAG = 0.06
local MISS_WINDOW_DURATION = 0.15

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local connections = {}
local healthConnections = {}
local carriedCharacter = nil
local wasCarrying = false
local pendingRelock = {}
local trackingState = {}
local lockedPartName = {}       -- current part name in the cycle
local lastPartCycleTime = {}    -- tick() when cycle last advanced
local partCycleIndex = {}       -- which index in CYCLE_PART_POOL we're currently on
local prevLockedPartName = {}   -- part name we're blending away from
local partTransitionStart = {}  -- tick() when the current blend started
local originalPartSizes = {}    -- [userId] = Vector3: actual in-game TargetPart size before we expand it

local function getTrackingState(userId)
    if not trackingState[userId] then
        trackingState[userId] = {
            smoothedVelocity = Vector3.zero,
            jumpSnapUntil = 0,
            anomalyMult = 1.0,
            missUntil = 0,
            missOffset = Vector3.zero,
        }
    end
    return trackingState[userId]
end

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 3})
    end)
end

local function isTyping()
    return UserInputService:GetFocusedTextBox() ~= nil
end

local pressTracker = {}

local function triplePress(actionId, callback)
    if not getgenv().SafeMode then
        callback()
        return
    end
    local now = tick()
    local entry = pressTracker[actionId]
    if not entry or (now - entry.lastTime) > TRIPLE_PRESS_WINDOW then
        pressTracker[actionId] = {count = 1, lastTime = now}
    else
        entry.count = entry.count + 1
        entry.lastTime = now
        if entry.count >= 3 then
            pressTracker[actionId] = nil
            callback()
        end
    end
end

-- =============================================
-- GUI
-- =============================================
local existingGui = LocalPlayer.PlayerGui:FindFirstChild("DemigodGui")
if existingGui then existingGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DemigodGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1000
screenGui.Parent = LocalPlayer.PlayerGui

local function makeDraggable(frame)
    local dragging = false
    local dragStart, startPos

    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local ORIGINAL_TRANSPARENCY = {
    xFrame = 0.3, cFrame = 0.3, zFrame = 0.3, emoteBtn = 0.15,
    -- vFrame removed — mobile mouse lock excised
    bracketBtn = 0,  -- bracketBtn is fully opaque (BackgroundTransparency = 0); 0.3 was wrong
}

-- X, C, Z all created together in one row this time — same shape, same position logic
local xFrame, xBtn, xDot, cFrame, cBtn, cDot, zFrame, zBtn, zDot
local wlToggleBtn, alToggleBtn, emoteBtn
-- vFrame/vBtn/vDot removed — mobile mouse lock excised entirely
-- mcFrame/mcBtn/mcDot fully removed, no declarations at all

if IS_MOBILE then
    -- X, C, Z — one row, bottom-center, identical shape/spacing
    xFrame = Instance.new("Frame")
    xFrame.Size = UDim2.new(0, 50, 0, 50)
    xFrame.Position = UDim2.new(0.5, -80, 1, -120)
    xFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    xFrame.BackgroundTransparency = 0.3
    xFrame.Active = true
    xFrame.ZIndex = 20
    xFrame.Parent = screenGui
    Instance.new("UICorner", xFrame).CornerRadius = UDim.new(1, 0)

    xBtn = Instance.new("TextButton")
    xBtn.Size = UDim2.new(1, 0, 1, 0)
    xBtn.BackgroundTransparency = 1
    xBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    xBtn.Text = "C"
    xBtn.Font = Enum.Font.GothamBold
    xBtn.TextSize = 22
    xBtn.Active = true
    xBtn.ZIndex = 21
    xBtn.Parent = xFrame

    xDot = Instance.new("Frame")
    xDot.Size = UDim2.new(0, 10, 0, 10)
    xDot.Position = UDim2.new(1, -2, 0, -2)
    xDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    xDot.ZIndex = 22
    xDot.Parent = xFrame
    Instance.new("UICorner", xDot).CornerRadius = UDim.new(1, 0)

    cFrame = Instance.new("Frame")
    cFrame.Size = UDim2.new(0, 50, 0, 50)
    cFrame.Position = UDim2.new(0.5, -25, 1, -120)
    cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    cFrame.BackgroundTransparency = 0.3
    cFrame.Active = true
    cFrame.ZIndex = 20
    cFrame.Parent = screenGui
    Instance.new("UICorner", cFrame).CornerRadius = UDim.new(1, 0)

    cBtn = Instance.new("TextButton")
    cBtn.Size = UDim2.new(1, 0, 1, 0)
    cBtn.BackgroundTransparency = 1
    cBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    cBtn.Text = "V"
    cBtn.Font = Enum.Font.GothamBold
    cBtn.TextSize = 22
    cBtn.Active = true
    cBtn.ZIndex = 21
    cBtn.Parent = cFrame

    cDot = Instance.new("Frame")
    cDot.Size = UDim2.new(0, 10, 0, 10)
    cDot.Position = UDim2.new(1, -2, 0, -2)
    cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    cDot.ZIndex = 22
    cDot.Parent = cFrame
    Instance.new("UICorner", cDot).CornerRadius = UDim.new(1, 0)

    zFrame = Instance.new("Frame")
    zFrame.Size = UDim2.new(0, 50, 0, 50)
    zFrame.Position = UDim2.new(0.5, 30, 1, -120)
    zFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    zFrame.BackgroundTransparency = 0.3
    zFrame.Active = true
    zFrame.ZIndex = 20
    zFrame.Parent = screenGui
    Instance.new("UICorner", zFrame).CornerRadius = UDim.new(1, 0)

    zBtn = Instance.new("TextButton")
    zBtn.Size = UDim2.new(1, 0, 1, 0)
    zBtn.BackgroundTransparency = 1
    zBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    zBtn.Text = "Z"
    zBtn.Font = Enum.Font.GothamBold
    zBtn.TextSize = 22
    zBtn.Active = true
    zBtn.ZIndex = 21
    zBtn.Parent = zFrame

    zDot = Instance.new("Frame")
    zDot.Size = UDim2.new(0, 10, 0, 10)
    zDot.Position = UDim2.new(1, -2, 0, -2)
    zDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    zDot.ZIndex = 22
    zDot.Parent = zFrame
    Instance.new("UICorner", zDot).CornerRadius = UDim.new(1, 0)

    -- WL, AL, Safe — one row, top-right, pointing right-upward
    wlToggleBtn = Instance.new("TextButton")
    wlToggleBtn.Size = UDim2.new(0, 46, 0, 40)
    wlToggleBtn.Position = UDim2.new(1, -156, 0, 10)
    wlToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    wlToggleBtn.BackgroundTransparency = 0.3
    wlToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    wlToggleBtn.Text = "WL"
    wlToggleBtn.Font = Enum.Font.GothamBold
    wlToggleBtn.TextSize = 14
    wlToggleBtn.Active = true
    wlToggleBtn.ZIndex = 20
    wlToggleBtn.Parent = screenGui
    Instance.new("UICorner", wlToggleBtn).CornerRadius = UDim.new(0, 8)

    alToggleBtn = Instance.new("TextButton")
    alToggleBtn.Size = UDim2.new(0, 46, 0, 40)
    alToggleBtn.Position = UDim2.new(1, -104, 0, 10)
    alToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    alToggleBtn.BackgroundTransparency = 0.3
    alToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    alToggleBtn.Text = "AL"
    alToggleBtn.Font = Enum.Font.GothamBold
    alToggleBtn.TextSize = 14
    alToggleBtn.Active = true
    alToggleBtn.ZIndex = 20
    alToggleBtn.Parent = screenGui
    Instance.new("UICorner", alToggleBtn).CornerRadius = UDim.new(0, 8)

    -- V button removed — mobile mouse lock excised entirely per request

    emoteBtn = Instance.new("TextButton")
    emoteBtn.Size = UDim2.new(0, 56, 0, 56)
    emoteBtn.Position = UDim2.new(0, 20, 0.5, -28)
    emoteBtn.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
    emoteBtn.BackgroundTransparency = 0.15
    emoteBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    emoteBtn.Text = "🎭"
    emoteBtn.Font = Enum.Font.GothamBold
    emoteBtn.TextSize = 24
    emoteBtn.Active = true
    emoteBtn.ZIndex = 20
    emoteBtn.Parent = screenGui
    Instance.new("UICorner", emoteBtn).CornerRadius = UDim.new(1, 0)
    makeDraggable(emoteBtn)

    -- Thumb-drag visuals removed — mobile mouse lock excised entirely
end

local function fireEmoteMenu()
    local VIM = game:GetService("VirtualInputManager")
    pcall(function()
        VIM:SendKeyEvent(true, Enum.KeyCode.Period, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.Period, false, game)
    end)
end

if emoteBtn then
    emoteBtn.MouseButton1Click:Connect(function()
        triplePress("emote", fireEmoteMenu)
    end)
end

local function updateXBtn(locked)
    if not xFrame then return end
    if locked then
        xFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        xDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        xFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        xDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local function updateCBtn()
    if not cFrame then return end
    if getgenv().HitboxVisible then
        cFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        cDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local function updateZBtn()
    if not zFrame then return end
    if getgenv().WallCheckEnabled then
        zFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        zDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        zFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        zDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

-- updateVBtn removed — mobile mouse lock excised entirely

-- =============================================
-- SAFE MODE — WL/AL text now correctly included in the
-- invisibility pass. Bug was: their entries had controls = {}
-- so the loop never touched their own TextTransparency.
-- Fix: iterate the buttons themselves too, not just controls.
-- =============================================
local safeModeBtn
local allMobileButtons = {}

if IS_MOBILE then
    safeModeBtn = Instance.new("TextButton")
    safeModeBtn.Size = UDim2.new(0, 46, 0, 40)
    safeModeBtn.Position = UDim2.new(1, -52, 0, 56)
    safeModeBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    safeModeBtn.BackgroundTransparency = 0
    safeModeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    safeModeBtn.Text = "Safe"
    safeModeBtn.Font = Enum.Font.GothamBold
    safeModeBtn.TextSize = 12
    safeModeBtn.Active = true
    safeModeBtn.ZIndex = 200
    safeModeBtn.Parent = screenGui
    Instance.new("UICorner", safeModeBtn).CornerRadius = UDim.new(0, 8)

    table.insert(allMobileButtons, {frame = xFrame, controls = {xBtn, xDot}, key = "xFrame"})
    table.insert(allMobileButtons, {frame = cFrame, controls = {cBtn, cDot}, key = "cFrame"})
    table.insert(allMobileButtons, {frame = zFrame, controls = {zBtn, zDot}, key = "zFrame"})
    -- FIX: WL/AL now pass themselves as their own text-bearing control
    table.insert(allMobileButtons, {frame = wlToggleBtn, controls = {wlToggleBtn}, key = "wlToggleBtn"})
    table.insert(allMobileButtons, {frame = alToggleBtn, controls = {alToggleBtn}, key = "alToggleBtn"})
    -- vFrame entry removed — mobile mouse lock excised
    if emoteBtn then table.insert(allMobileButtons, {frame = emoteBtn, controls = {}, key = "emoteBtn"}) end
end

local function applySafeModeVisual()
    if not IS_MOBILE then return end

    if getgenv().SafeMode then
        safeModeBtn.BackgroundTransparency = 1
        safeModeBtn.TextTransparency = 1

        for _, entry in ipairs(allMobileButtons) do
            entry.frame.BackgroundTransparency = 1
            for _, ctrl in ipairs(entry.controls) do
                if ctrl:IsA("TextButton") or ctrl:IsA("TextLabel") then
                    ctrl.TextTransparency = 1
                end
                ctrl.BackgroundTransparency = 1
            end
        end
    else
        safeModeBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        safeModeBtn.BackgroundTransparency = 0
        safeModeBtn.TextTransparency = 0

        for _, entry in ipairs(allMobileButtons) do
            entry.frame.BackgroundTransparency = ORIGINAL_TRANSPARENCY[entry.key] or 0.3
            for _, ctrl in ipairs(entry.controls) do
                if ctrl:IsA("TextButton") then
                    ctrl.TextTransparency = 0
                    -- WL/AL are self-referential controls (button IS the frame),
                    -- so don't blank their background here — only X/C/Z's
                    -- separate inner buttons stay background-transparent
                    if ctrl ~= entry.frame then
                        ctrl.BackgroundTransparency = 1
                    end
                elseif ctrl:IsA("Frame") then
                    ctrl.BackgroundTransparency = 0
                end
            end
        end

        updateXBtn(getgenv().CamlockTarget ~= nil)
        updateCBtn()
        updateZBtn()
        updateBracketBtn()
    end
end

local function toggleSafeMode()
    getgenv().SafeMode = not getgenv().SafeMode
    applySafeModeVisual()
end

if IS_MOBILE then
    local safeModePressCount = 0
    local safeModeLastPress = 0

    safeModeBtn.MouseButton1Click:Connect(function()
        local now = tick()
        if (now - safeModeLastPress) > TRIPLE_PRESS_WINDOW then
            safeModePressCount = 1
        else
            safeModePressCount = safeModePressCount + 1
        end
        safeModeLastPress = now

        if safeModePressCount >= 3 then
            safeModePressCount = 0
            toggleSafeMode()
        end
    end)
end

-- =============================================
-- WHITELIST / AUTO-LOCK MENUS (unchanged positions — left/right)
-- =============================================
local whitelistGui = Instance.new("Frame")
whitelistGui.Size = UDim2.new(0, 220, 0, 300)
whitelistGui.Position = UDim2.new(0, 20, 0.5, -150)
whitelistGui.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
whitelistGui.Visible = false
whitelistGui.Active = true
whitelistGui.ZIndex = 60
whitelistGui.Parent = screenGui
Instance.new("UICorner", whitelistGui).CornerRadius = UDim.new(0, 8)

local wlTitle = Instance.new("TextLabel")
wlTitle.Size = UDim2.new(1, 0, 0, 30)
wlTitle.BackgroundTransparency = 1
wlTitle.Text = "Whitelist"
wlTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
wlTitle.Font = Enum.Font.GothamBold
wlTitle.TextSize = 16
wlTitle.ZIndex = 61
wlTitle.Parent = whitelistGui

local wlScroll = Instance.new("ScrollingFrame")
wlScroll.Size = UDim2.new(1, -10, 1, -40)
wlScroll.Position = UDim2.new(0, 5, 0, 32)
wlScroll.BackgroundTransparency = 1
wlScroll.ScrollBarThickness = 4
wlScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
wlScroll.ZIndex = 61
wlScroll.Parent = whitelistGui

local wlLayout = Instance.new("UIListLayout")
wlLayout.Padding = UDim.new(0, 4)
wlLayout.Parent = wlScroll

local autoLockGui = Instance.new("Frame")
autoLockGui.Size = UDim2.new(0, 220, 0, 300)
autoLockGui.Position = UDim2.new(1, -240, 0.5, -150)
autoLockGui.BackgroundColor3 = Color3.fromRGB(30, 40, 30)
autoLockGui.Visible = false
autoLockGui.Active = true
autoLockGui.ZIndex = 60
autoLockGui.Parent = screenGui
Instance.new("UICorner", autoLockGui).CornerRadius = UDim.new(0, 8)

local alTitle = Instance.new("TextLabel")
alTitle.Size = UDim2.new(1, 0, 0, 30)
alTitle.BackgroundTransparency = 1
alTitle.Text = "Auto-Lock"
alTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
alTitle.Font = Enum.Font.GothamBold
alTitle.TextSize = 16
alTitle.ZIndex = 61
alTitle.Parent = autoLockGui

local alEnableBtn = Instance.new("TextButton")
alEnableBtn.Size = UDim2.new(1, -10, 0, 28)
alEnableBtn.Position = UDim2.new(0, 5, 0, 32)
alEnableBtn.BackgroundColor3 = Color3.fromRGB(90, 80, 60)
alEnableBtn.Text = "Auto-Lock: OFF"
alEnableBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
alEnableBtn.Font = Enum.Font.GothamBold
alEnableBtn.TextSize = 12
alEnableBtn.Active = true
alEnableBtn.ZIndex = 61
alEnableBtn.Parent = autoLockGui
Instance.new("UICorner", alEnableBtn).CornerRadius = UDim.new(0, 6)

local alStatusLabel = Instance.new("TextLabel")
alStatusLabel.Size = UDim2.new(1, -10, 0, 20)
alStatusLabel.Position = UDim2.new(0, 5, 0, 62)
alStatusLabel.BackgroundTransparency = 1
alStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
alStatusLabel.Text = "Pool empty"
alStatusLabel.Font = Enum.Font.Gotham
alStatusLabel.TextSize = 11
alStatusLabel.ZIndex = 61
alStatusLabel.Parent = autoLockGui

local alScroll = Instance.new("ScrollingFrame")
alScroll.Size = UDim2.new(1, -10, 1, -92)
alScroll.Position = UDim2.new(0, 5, 0, 86)
alScroll.BackgroundTransparency = 1
alScroll.ScrollBarThickness = 4
alScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
alScroll.ZIndex = 61
alScroll.Parent = autoLockGui

local alLayout = Instance.new("UIListLayout")
alLayout.Padding = UDim.new(0, 4)
alLayout.Parent = alScroll

local function clearChildren(parent)
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
end

local pooledNameCache = getgenv().PooledNameCache or {}
getgenv().PooledNameCache = pooledNameCache

local function rebuildWhitelistGui()
    clearChildren(wlScroll)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 30)
            row.BackgroundColor3 = getgenv().Whitelist[player.UserId]
                and Color3.fromRGB(60, 120, 60)
                or Color3.fromRGB(50, 50, 60)
            row.Text = player.Name .. (getgenv().Whitelist[player.UserId] and " ✓" or "")
            row.TextColor3 = Color3.fromRGB(255, 255, 255)
            row.Font = Enum.Font.Gotham
            row.TextSize = 12
            row.ZIndex = 61
            row.Parent = wlScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

            row.MouseButton1Click:Connect(function()
                triplePress("wl_" .. player.UserId, function()
                    getgenv().Whitelist[player.UserId] = not getgenv().Whitelist[player.UserId] or nil
                    if getgenv().Whitelist[player.UserId] and getgenv().CamlockTarget == player then
                        getgenv().CamlockTarget = nil
                        updateXBtn(false)
                    end
                    rebuildWhitelistGui()
                end)
            end)
        end
    end
    wlScroll.CanvasSize = UDim2.new(0, 0, 0, wlLayout.AbsoluteContentSize.Y + 10)
end

local function rebuildAutoLockGui()
    clearChildren(alScroll)
    local onlineIds = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            onlineIds[player.UserId] = true
            pooledNameCache[player.UserId] = player.Name

            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 30)
            row.BackgroundColor3 = getgenv().AutoLockPool[player.UserId]
                and Color3.fromRGB(60, 120, 60)
                or Color3.fromRGB(50, 50, 60)
            row.Text = player.Name .. (getgenv().AutoLockPool[player.UserId] and " ✓ (pooled)" or "")
            row.TextColor3 = Color3.fromRGB(255, 255, 255)
            row.Font = Enum.Font.Gotham
            row.TextSize = 12
            row.ZIndex = 61
            row.Parent = alScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

            row.MouseButton1Click:Connect(function()
                triplePress("al_" .. player.UserId, function()
                    getgenv().AutoLockPool[player.UserId] = not getgenv().AutoLockPool[player.UserId] or nil
                    rebuildAutoLockGui()
                end)
            end)
        end
    end

    for userId in pairs(getgenv().AutoLockPool) do
        if not onlineIds[userId] then
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 30)
            row.BackgroundColor3 = Color3.fromRGB(60, 90, 60)
            row.Text = (pooledNameCache[userId] or ("ID " .. userId)) .. " ✓ (pooled, offline)"
            row.TextColor3 = Color3.fromRGB(200, 255, 200)
            row.Font = Enum.Font.Gotham
            row.TextSize = 11
            row.ZIndex = 61
            row.Parent = alScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

            row.MouseButton1Click:Connect(function()
                triplePress("al_offline_" .. userId, function()
                    getgenv().AutoLockPool[userId] = nil
                    rebuildAutoLockGui()
                end)
            end)
        end
    end

    alScroll.CanvasSize = UDim2.new(0, 0, 0, alLayout.AbsoluteContentSize.Y + 10)
end

alEnableBtn.MouseButton1Click:Connect(function()
    triplePress("al_enable", function()
        getgenv().AutoLockEnabled = not getgenv().AutoLockEnabled
        alEnableBtn.Text = "Auto-Lock: " .. (getgenv().AutoLockEnabled and "ON" or "OFF")
        alEnableBtn.BackgroundColor3 = getgenv().AutoLockEnabled
            and Color3.fromRGB(60, 120, 60)
            or Color3.fromRGB(90, 80, 60)
        if not getgenv().AutoLockEnabled then
            alStatusLabel.Text = "Off"
        end
    end)
end)

if wlToggleBtn then
    wlToggleBtn.MouseButton1Click:Connect(function()
        triplePress("wl_toggle", function()
            whitelistGui.Visible = not whitelistGui.Visible
        end)
    end)
    alToggleBtn.MouseButton1Click:Connect(function()
        triplePress("al_toggle", function()
            autoLockGui.Visible = not autoLockGui.Visible
        end)
    end)
    zBtn.MouseButton1Click:Connect(function()
        triplePress("z_btn", function()
            getgenv().WallCheckEnabled = not getgenv().WallCheckEnabled
            updateZBtn()
        end)
    end)
end

-- vBtn click handler removed — mobile mouse lock excised entirely

-- =============================================
-- HITBOX FUNCTIONS
-- =============================================
local function disableAllCollision(character)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then part.CanCollide = false end
    end
end

local function restoreCollision(character)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= getgenv().TargetPart then
            part.CanCollide = true
        end
    end
end

local function removeHitbox(player)
    if not player.Character then return end
    local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
    if not targetPart or not targetPart:IsA("BasePart") then return end

    local userId = player.UserId
    if connections[userId] then
        for _, conn in ipairs(connections[userId]) do conn:Disconnect() end
        connections[userId] = {}
    end

    targetPart.Size = Vector3.new(2, 2, 1)
    targetPart.CanCollide = true
    targetPart.Transparency = 1
end

local function applyHitbox(player)
    if not getgenv().Enabled or player == LocalPlayer then return end
    if getgenv().Whitelist[player.UserId] then return end
    if not player.Character then return end

    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= KNOCK_THRESHOLD then return end

    local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
    if not targetPart or not targetPart:IsA("BasePart") then return end

    -- Capture the ACTUAL in-game size before we touch it, so ] can restore
    -- to the real game value instead of a hardcoded guess.
    local userId = player.UserId
    if not originalPartSizes[userId] then
        originalPartSizes[userId] = targetPart.Size
    end

    targetPart.Size = getgenv().HitboxSize
    targetPart.Transparency = getgenv().HitboxVisible and 0.5 or 1
    targetPart.CanCollide = false
    disableAllCollision(player.Character)

    if connections[userId] then
        for _, conn in ipairs(connections[userId]) do conn:Disconnect() end
    end
    connections[userId] = {}

    table.insert(connections[userId], targetPart:GetPropertyChangedSignal("Size"):Connect(function()
        if targetPart.Size ~= getgenv().HitboxSize then targetPart.Size = getgenv().HitboxSize end
    end))
    table.insert(connections[userId], targetPart:GetPropertyChangedSignal("CanCollide"):Connect(function()
        if targetPart.CanCollide ~= false then targetPart.CanCollide = false end
    end))
end

local function setupHealthWatch(player)
    if player == LocalPlayer then return end
    local userId = player.UserId
    if healthConnections[userId] then
        healthConnections[userId]:Disconnect()
        healthConnections[userId] = nil
    end
    if not player.Character then return end
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    healthConnections[userId] = humanoid:GetPropertyChangedSignal("Health"):Connect(function()
        if humanoid.Health <= KNOCK_THRESHOLD then removeHitbox(player) end
    end)
end

local function updateVisibility()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and not getgenv().Whitelist[player.UserId] then
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > KNOCK_THRESHOLD then
                local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
                if targetPart and targetPart:IsA("BasePart") then
                    targetPart.Transparency = getgenv().HitboxVisible and 0.5 or 1
                end
            end
        end
    end
end

local function toggleHitboxVisibility()
    getgenv().HitboxVisible = not getgenv().HitboxVisible
    updateVisibility()
    updateCBtn()
end

if cBtn then
    cBtn.MouseButton1Click:Connect(function()
        triplePress("v_btn", toggleHitboxVisibility)
    end)
end

-- =============================================
-- ] KEYBIND — ORIGINAL HITBOX TOGGLE
-- Swaps hitbox expander OFF: restores real game part sizes and
-- CanCollide=true so the character behaves exactly as the real game
-- intended. Does NOT touch Transparency — visibility state is untouched.
-- Re-press ] to bring the expanded hitbox back.
-- Mobile: bracketBtn sits next to Safe button.
-- =============================================
getgenv().OriginalHitboxActive = false

-- ORIGINAL_PART_SIZES removed — restoreOriginalHitboxes now uses
-- originalPartSizes[userId] captured from the real game before expansion.

local bracketBtn  -- mobile-only, declared here for updateBracketBtn scope

local function restoreOriginalHitboxes()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local userId = player.UserId
            -- Disconnect size-lock watchers so they don't fight the restore
            if connections[userId] then
                for _, conn in ipairs(connections[userId]) do conn:Disconnect() end
                connections[userId] = {}
            end
            local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
            if targetPart and targetPart:IsA("BasePart") then
                -- Restore to the actual captured in-game size, not a hardcoded value
                local origSize = originalPartSizes[userId] or Vector3.new(2, 2, 1)
                targetPart.Size        = origSize
                targetPart.CanCollide  = true
                targetPart.Transparency = 1
            end
            -- Re-enable collision on all other parts that disableAllCollision zeroed out
            restoreCollision(player.Character)
        end
    end
end

local function reapplyExpandedHitboxes()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            applyHitbox(player)
        end
    end
end

local function updateBracketBtn()
    if not IS_MOBILE or not bracketBtn then return end
    if getgenv().OriginalHitboxActive then
        bracketBtn.BackgroundColor3 = Color3.fromRGB(180, 120, 10)
        bracketBtn.TextColor3 = Color3.fromRGB(255, 230, 120)
    else
        bracketBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        bracketBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    end
end

local function toggleOriginalHitbox()
    getgenv().OriginalHitboxActive = not getgenv().OriginalHitboxActive
    if getgenv().OriginalHitboxActive then
        restoreOriginalHitboxes()
    else
        reapplyExpandedHitboxes()
    end
    updateBracketBtn()
end

-- Mobile ] button — sits immediately to the left of Safe button
if IS_MOBILE then
    bracketBtn = Instance.new("TextButton")
    bracketBtn.Size = UDim2.new(0, 46, 0, 40)
    -- Safe is at (1, -52, 0, 56); bracket sits one slot left at (1, -104, 0, 56)
    bracketBtn.Position = UDim2.new(1, -104, 0, 56)
    bracketBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    bracketBtn.BackgroundTransparency = 0
    bracketBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    bracketBtn.Text = "]"
    bracketBtn.Font = Enum.Font.GothamBold
    bracketBtn.TextSize = 16
    bracketBtn.Active = true
    bracketBtn.ZIndex = 200
    bracketBtn.Parent = screenGui
    Instance.new("UICorner", bracketBtn).CornerRadius = UDim.new(0, 8)

    table.insert(allMobileButtons, {frame = bracketBtn, controls = {bracketBtn}, key = "bracketBtn"})

    local bracketPressCount = 0
    local bracketLastPress  = 0
    bracketBtn.MouseButton1Click:Connect(function()
        -- Single press — ] is a toggle, not a safety gate
        toggleOriginalHitbox()
    end)
end

-- =============================================
-- TARGETING CORE
-- =============================================
local function isKnockedOrDead(player)
    if not player or not player.Character then return true end
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return true end
    local ok, health = pcall(function() return humanoid.Health end)
    if not ok then return true end
    return health <= KNOCK_THRESHOLD
end

local function isEligibleTarget(player)
    if isKnockedOrDead(player) then return false end
    if pendingRelock[player.UserId] then return false end
    return true
end

local cachedExclusions = {}
local cachedExclusionsFrame = -1
local frameCounter = 0

local function getFrameExclusions()
    if cachedExclusionsFrame ~= frameCounter then
        cachedExclusions = {}
        local localChar = LocalPlayer.Character
        if localChar then table.insert(cachedExclusions, localChar) end
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Character and p.Character ~= localChar then
                table.insert(cachedExclusions, p.Character)
            end
        end
        cachedExclusionsFrame = frameCounter
    end
    return cachedExclusions
end

local function hasLineOfSight(targetHRP)
    if not getgenv().WallCheckEnabled then return true end
    local localChar = LocalPlayer.Character
    if not localChar then return false end
    local origin = Camera.CFrame.Position
    local direction = targetHRP.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = getFrameExclusions()
    return workspace:Raycast(origin, direction.Unit * direction.Magnitude, params) == nil
end

-- pickRandomTargetPart removed — replaced by sequential cycle in getAimPoint

local anomalyCache = {}

local function detectAnomaly(userId, hrp, humanoid)
    local now = tick()
    local cache = anomalyCache[userId]
    if not cache then
        cache = {lastPos = hrp.Position, lastTime = now, lastVel = Vector3.zero}
        anomalyCache[userId] = cache
        return "normal"
    end

    local dt = now - cache.lastTime
    if dt <= 0 then return "normal" end

    local posDelta = hrp.Position - cache.lastPos
    local instVel = posDelta / dt
    local velDelta = instVel - cache.lastVel
    local accelMag = velDelta.Magnitude / dt

    cache.lastPos = hrp.Position
    cache.lastVel = instVel
    cache.lastTime = now

    local isAirborne = humanoid and humanoid:GetState() == Enum.HumanoidStateType.Freefall
    if isAirborne and instVel.Y > FLYING_Y_VEL_THRESHOLD then
        return "flying"
    end

    if accelMag > CFRAME_ACCEL_SPIKE then
        return "cframe"
    end

    local horizVel = Vector3.new(instVel.X, 0, instVel.Z).Magnitude
    if horizVel > SPEEDHACK_VEL_THRESHOLD then
        return "speedhack"
    end

    if instVel.Magnitude > 20 and velDelta.Magnitude > 15 and accelMag < CFRAME_ACCEL_SPIKE then
        return "macro"
    end

    return "normal"
end

local function getSpeedMultiplierFor(anomaly)
    if anomaly == "flying" then return FLYING_TRACK_RATE_MULT end
    if anomaly == "cframe" then return CFRAME_TRACK_RATE_MULT end
    if anomaly == "macro" then return MACRO_SPEED_MULT end
    return 1.0
end

local function updateTrackingState(userId, refPart, humanoid, dt)
    local state = getTrackingState(userId)
    local rawVel = refPart.AssemblyLinearVelocity

    local filterAlpha = 1 - math.exp(-VELOCITY_SMOOTH_RATE * dt)
    state.smoothedVelocity = state.smoothedVelocity:Lerp(rawVel, filterAlpha)

    if rawVel.Y > JUMP_VEL_THRESHOLD then
        state.jumpSnapUntil = tick() + JUMP_SNAP_DURATION
    end

    local anomaly = detectAnomaly(userId, refPart, humanoid)
    state.anomalyMult = getSpeedMultiplierFor(anomaly)

    if tick() > state.missUntil and math.random() < (MISS_CHANCE_PER_SECOND * dt) then
        state.missUntil = tick() + MISS_WINDOW_DURATION
        state.missOffset = Vector3.new(
            (math.random() - 0.5) * MISS_OFFSET_MAG,
            (math.random() - 0.5) * MISS_OFFSET_MAG,
            0
        )
    end

    return state
end

-- Sequential body-scan: advances through CYCLE_PART_POOL in order every
-- PART_CYCLE_INTERVAL seconds. During the first PART_TRANSITION_DURATION
-- of each interval the aim point smoothstep-blends from the previous part
-- to the new one, so every "snap" is actually an S-curve glide.
local function getAimPoint(character, humanoid, userId, dt)
    local now = tick()
    local poolSize = #CYCLE_PART_POOL

    -- Advance cycle index when the current interval expires
    if not lastPartCycleTime[userId] or (now - lastPartCycleTime[userId]) >= PART_CYCLE_INTERVAL then
        local prevIdx  = partCycleIndex[userId] or 0
        -- Skip parts the character doesn't have (some R16 rigs drop extremities)
        local nextIdx  = prevIdx
        local attempts = 0
        repeat
            nextIdx  = (nextIdx % poolSize) + 1
            attempts = attempts + 1
        until character:FindFirstChild(CYCLE_PART_POOL[nextIdx]) or attempts > poolSize

        prevLockedPartName[userId]  = lockedPartName[userId]
        partCycleIndex[userId]      = nextIdx
        lockedPartName[userId]      = CYCLE_PART_POOL[nextIdx]
        partTransitionStart[userId] = now
        lastPartCycleTime[userId]   = now
    end

    -- Resolve current part, fall back to HRP on failure
    local curPart = character:FindFirstChild(lockedPartName[userId] or "HumanoidRootPart")
    if not curPart or not curPart:IsA("BasePart") then
        curPart = character:FindFirstChild("HumanoidRootPart")
        lockedPartName[userId] = "HumanoidRootPart"
    end
    if not curPart then return nil end

    local state    = updateTrackingState(userId, curPart, humanoid, dt)
    local leadTime = LEAD_TIME * (state.anomalyMult > 1.0 and state.anomalyMult or 1.0) * 0.6
        + (state.anomalyMult == MACRO_SPEED_MULT and LEAD_TIME * 0.2 or 0)

    local curPos = curPart.Position + (state.smoothedVelocity * leadTime)

    local now2        = tick()
    local inSnapWindow = now2 < state.jumpSnapUntil

    -- Smoothstep S-curve blend from previous part position during transition window.
    -- rawAlpha 0→1 over PART_TRANSITION_DURATION; smoothstep gives an ease-in-out curve.
    -- BYPASSED when inSnapWindow — the blend dampens the snap if left active,
    -- so we pass the raw aim point straight through and let JUMP_SNAP_RATE handle it.
    if not inSnapWindow then
        local transAge   = now2 - (partTransitionStart[userId] or now2)
        local rawAlpha   = math.min(transAge / PART_TRANSITION_DURATION, 1.0)
        local blendAlpha = rawAlpha * rawAlpha * (3.0 - 2.0 * rawAlpha)  -- smoothstep

        if blendAlpha < 1.0 then
            local prevName = prevLockedPartName[userId]
            if prevName then
                local prevPart = character:FindFirstChild(prevName)
                if prevPart and prevPart:IsA("BasePart") then
                    local prevPos = prevPart.Position + (state.smoothedVelocity * leadTime)
                    curPos = prevPos:Lerp(curPos, blendAlpha)
                end
            end
        end
    end

    if now2 < state.missUntil then
        curPos = curPos + state.missOffset
    end

    return curPos, inSnapWindow, state.anomalyMult
end

local function getPlayerInCrosshair()
    local best, bestDot = nil, -math.huge
    local look = Camera.CFrame.LookVector
    local camPos = Camera.CFrame.Position

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not getgenv().Whitelist[player.UserId] and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hrp and hrp:IsDescendantOf(workspace) and isEligibleTarget(player) then
                if hasLineOfSight(hrp) then
                    local dot = look:Dot((hrp.Position - camPos).Unit)
                    if dot > bestDot then
                        bestDot = dot
                        best = player
                    end
                end
            end
        end
    end
    return best
end

local function getAutoLockTarget()
    local best, bestHealth, bestDist = nil, math.huge, math.huge
    local localChar = LocalPlayer.Character
    local localHRP = localChar and localChar:FindFirstChild("HumanoidRootPart")
    if not localHRP then return nil end

    local wallCheckOff = not getgenv().WallCheckEnabled
    local fullHealthCandidates = {}

    for userId in pairs(getgenv().AutoLockPool) do
        if userId ~= LocalPlayer.UserId then
            local player = Players:GetPlayerByUserId(userId)
            if player and player ~= LocalPlayer and not getgenv().Whitelist[userId]
                and player.Character and not pendingRelock[userId] then

                local hum = player.Character:FindFirstChildOfClass("Humanoid")
                local hrp = player.Character:FindFirstChild("HumanoidRootPart")

                if hum and hrp and hrp:IsDescendantOf(workspace) then
                    local ok, health = pcall(function() return hum.Health end)

                    if ok and health > KNOCK_THRESHOLD then
                        if hasLineOfSight(hrp) then
                            local dist = (hrp.Position - localHRP.Position).Magnitude

                            if wallCheckOff then
                                if dist < bestDist then
                                    bestDist, best = dist, player
                                end
                            elseif health >= MAX_HEALTH then
                                table.insert(fullHealthCandidates, {player = player, dist = dist})
                            elseif health < bestHealth or (health == bestHealth and dist < bestDist) then
                                bestHealth, bestDist, best = health, dist, player
                            end
                        end
                    end
                end
            end
        else
            getgenv().AutoLockPool[userId] = nil
        end
    end

    if not wallCheckOff and #fullHealthCandidates > 0 and best == nil then
        local nearest, nearestDist = nil, math.huge
        for _, c in ipairs(fullHealthCandidates) do
            if c.dist < nearestDist then
                nearestDist, nearest = c.dist, c.player
            end
        end
        return nearest
    end

    return best
end

local function releaseTarget()
    local target = getgenv().CamlockTarget
    if target then
        local uid = target.UserId
        lockedPartName[uid]      = nil
        lastPartCycleTime[uid]   = nil
        partCycleIndex[uid]      = nil
        prevLockedPartName[uid]  = nil
        partTransitionStart[uid] = nil
    end
    getgenv().CamlockTarget = nil
    updateXBtn(false)
end

local function handleLockToggle()
    if isTyping() then return end
    if getgenv().CamlockTarget then
        releaseTarget()
    else
        local target = getPlayerInCrosshair()
        if target and target ~= LocalPlayer then
            getgenv().CamlockTarget = target
            local uid = target.UserId
            trackingState[uid]       = nil
            lockedPartName[uid]      = nil
            lastPartCycleTime[uid]   = nil
            -- partCycleIndex persists — cycle continues from wherever it was,
            -- guaranteeing a different starting part on every re-lock
            prevLockedPartName[uid]  = nil  -- clear blend state for clean transition
            partTransitionStart[uid] = nil
            updateXBtn(true)
        end
    end
end

if xBtn then
    xBtn.MouseButton1Click:Connect(function()
        -- Isolated actionId — never shares state with c_key_pc.
        -- Tracker entry cleared on success so no permanent throttle across lock/unlock cycles.
        triplePress("c_btn_mobile", function()
            handleLockToggle()
            pressTracker["c_btn_mobile"] = nil
        end)
    end)
end

-- =============================================
-- MAIN CAMLOCK
-- =============================================
Camera.CameraType = Enum.CameraType.Custom
pcall(function() RunService:UnbindFromRenderStep("DemigodCamlock") end)

RunService:BindToRenderStep("DemigodCamlock", Enum.RenderPriority.Camera.Value + 1, function(dt)
    frameCounter = frameCounter + 1

    local localChar = LocalPlayer.Character
    local localHum = localChar and localChar:FindFirstChildOfClass("Humanoid")
    if localHum then
        local ok, localHealth = pcall(function() return localHum.Health end)
        if ok and localHealth < LOCAL_HEALTH_GATE then
            if getgenv().CamlockTarget then releaseTarget() end
            return
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local userId = player.UserId
            if player.Character then
                local hum = player.Character:FindFirstChildOfClass("Humanoid")
                if hum then
                    local ok, health = pcall(function() return hum.Health end)
                    if ok then
                        if health <= KNOCK_THRESHOLD then
                            pendingRelock[userId] = true
                        elseif pendingRelock[userId] and health >= RELOCK_THRESHOLD then
                            pendingRelock[userId] = nil
                        end
                    end
                end
            end
        end
    end

    if getgenv().AutoLockEnabled then
        if next(getgenv().AutoLockPool) ~= nil then
            local autoTarget = getAutoLockTarget()
            if autoTarget then
                if getgenv().CamlockTarget ~= autoTarget then
                    local uid = autoTarget.UserId
                    trackingState[uid]       = nil
                    lockedPartName[uid]      = nil
                    lastPartCycleTime[uid]   = nil
                    -- partCycleIndex persists — different starting part on every target switch
                    prevLockedPartName[uid]  = nil
                    partTransitionStart[uid] = nil
                end
                getgenv().CamlockTarget = autoTarget
                updateXBtn(true)
                if IS_MOBILE then alStatusLabel.Text = "Tracking: " .. autoTarget.Name end
            else
                if getgenv().CamlockTarget then releaseTarget() end
                if IS_MOBILE then alStatusLabel.Text = "Pool: waiting (knocked/offline)" end
            end
        else
            if getgenv().CamlockTarget then releaseTarget() end
            if IS_MOBILE then alStatusLabel.Text = "Pool empty" end
        end
    end

    local target = getgenv().CamlockTarget
    if not target then return end

    if target == LocalPlayer then releaseTarget(); return end
    if getgenv().Whitelist[target.UserId] then releaseTarget(); return end
    if pendingRelock[target.UserId] then releaseTarget(); return end
    if not target.Character then releaseTarget(); return end

    local hum = target.Character:FindFirstChildOfClass("Humanoid")
    if not hum then releaseTarget(); return end

    local ok, health = pcall(function() return hum.Health end)
    if not ok or health <= KNOCK_THRESHOLD then releaseTarget(); return end

    local hrpCheck = target.Character:FindFirstChild("HumanoidRootPart")
    if not hrpCheck or not hrpCheck:IsDescendantOf(workspace) then releaseTarget(); return end

    if not hasLineOfSight(hrpCheck) then return end

    local camCF = Camera.CFrame
    local camPos = camCF.Position
    local currentLook = camCF.LookVector

    local aimPoint, inSnapWindow, speedMult = getAimPoint(target.Character, hum, target.UserId, dt)
    if not aimPoint then return end

    local toTarget = aimPoint - camPos
    if toTarget.Magnitude < 0.1 then return end

    local targetDir = toTarget.Unit

    local rate = (inSnapWindow and JUMP_SNAP_RATE or LOOK_SMOOTH_RATE) * speedMult
    local alpha = 1 - math.exp(-rate * dt)

    local jitterX = (math.random() - 0.5) * LOOK_JITTER_MAG
    local jitterY = (math.random() - 0.5) * LOOK_JITTER_MAG
    local jitteredDir = (targetDir + Vector3.new(jitterX, jitterY, 0)).Unit

    local newLook = currentLook:Lerp(jitteredDir, alpha)
    if newLook.Magnitude < 0.001 then return end

    Camera.CFrame = CFrame.new(camPos, camPos + newLook)
end)

-- Mobile Mouse Lock removed entirely per request.
-- DemigodMobileMouseLock render step not bound.
pcall(function() RunService:UnbindFromRenderStep("DemigodMobileMouseLock") end)

-- =============================================
-- MC — MOUSE CAMLOCK (PC only)
-- When MouseCamlockEnabled, left-click acquires the nearest eligible
-- target to the cursor position instead of requiring X.
-- Right-click releases. Toggled by M key.
-- =============================================
if not IS_MOBILE then
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if not getgenv().MouseCamlockEnabled then return end
        if gameProcessed then return end
        if isTyping() then return end

        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            -- Acquire: pick the player closest to crosshair, same as X
            if not getgenv().CamlockTarget then
                local target = getPlayerInCrosshair()
                if target and target ~= LocalPlayer then
                    getgenv().CamlockTarget = target
                    trackingState[target.UserId] = nil
                    lockedPartName[target.UserId] = nil
                    lastPartCycleTime[target.UserId] = nil
                end
            end
        elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
            -- Right-click releases current lock when MC is active
            if getgenv().CamlockTarget then
                releaseTarget()
            end
        end
    end)
end

-- =============================================
-- CARRY DETECTION — visual notification only
-- =============================================
local function getCarriedCharacter()
    local character = LocalPlayer.Character
    if not character then return nil end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    for _, weld in ipairs(hrp:GetChildren()) do
        if weld:IsA("WeldConstraint") or weld:IsA("Weld") then
            local otherPart = weld.Part1
            if otherPart and otherPart.Parent and otherPart.Parent ~= character then
                return otherPart.Parent
            end
        end
    end
    for _, weld in ipairs(character:GetDescendants()) do
        if weld:IsA("WeldConstraint") or weld:IsA("Weld") then
            local otherPart = weld.Part1
            if otherPart and otherPart.Parent and otherPart.Parent ~= character
                and otherPart.Parent:FindFirstChildOfClass("Humanoid") then
                return otherPart.Parent
            end
        end
    end
    return nil
end

local function getCarrierOf(knockedCharacter)
    local hrp = knockedCharacter:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    for _, weld in ipairs(hrp:GetChildren()) do
        if weld:IsA("WeldConstraint") or weld:IsA("Weld") then
            local otherPart = weld.Part1
            if otherPart and otherPart.Parent and otherPart.Parent ~= knockedCharacter then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p.Character == otherPart.Parent then
                        return p
                    end
                end
            end
        end
    end
    return nil
end

local notifiedCarries = {}

task.spawn(function()
    while true do
        task.wait(0.3)
        local character = LocalPlayer.Character
        local detected = getCarriedCharacter()
        local carrying = detected ~= nil

        if carrying and not wasCarrying then
            disableAllCollision(character)
            disableAllCollision(detected)
            carriedCharacter = detected
            wasCarrying = true
        elseif not carrying and wasCarrying then
            restoreCollision(character)
            if carriedCharacter then restoreCollision(carriedCharacter) end
            carriedCharacter = nil
            wasCarrying = false
        elseif carrying and wasCarrying then
            disableAllCollision(character)
            disableAllCollision(detected)
        end

        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local hum = p.Character:FindFirstChildOfClass("Humanoid")
                if hum then
                    local ok, health = pcall(function() return hum.Health end)
                    if ok and health <= KNOCK_THRESHOLD then
                        local carrier = getCarrierOf(p.Character)
                        if carrier and not notifiedCarries[p.UserId] then
                            notifiedCarries[p.UserId] = true
                            notify("Carry Detected", carrier.Name .. " is carrying " .. p.Name, 3)
                        end
                    else
                        notifiedCarries[p.UserId] = nil
                    end
                end
            end
        end
    end
end)

-- =============================================
-- VALIDATION
-- =============================================
local function validateHitboxes()
    -- When ] is active, original hitboxes are intentionally restored.
    -- Don't fight it — skip the whole pass.
    if getgenv().OriginalHitboxActive then return end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and not getgenv().Whitelist[player.UserId] then
            local hum = player.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health <= KNOCK_THRESHOLD then continue end
            local tp = player.Character:FindFirstChild(getgenv().TargetPart)
            if tp and tp:IsA("BasePart") then
                local sizeMatch = tp.Size.X == getgenv().HitboxSize.X
                    and tp.Size.Y == getgenv().HitboxSize.Y
                    and tp.Size.Z == getgenv().HitboxSize.Z
                if not sizeMatch or tp.CanCollide ~= false then
                    applyHitbox(player)
                end
            end
        end
    end
end

-- =============================================
-- KEYBINDS
-- "]" moved to Semicolon — RightBracket was still suspect as a
-- Da Hood/Roblox default. Semicolon has near-zero collision risk.
-- =============================================
local pPressCount = 0
local pLastPress = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if isTyping() then return end

    if input.KeyCode == Enum.KeyCode.C then
        -- PC camlock toggle — C key, isolated from mobile c_btn_mobile
        triplePress("c_key_pc", handleLockToggle)
    elseif input.KeyCode == Enum.KeyCode.V then
        triplePress("v_key", toggleHitboxVisibility)
    elseif input.KeyCode == Enum.KeyCode.Semicolon then
        triplePress("semicolon_key", toggleHitboxVisibility)
    elseif input.KeyCode == Enum.KeyCode.RightBracket then
        -- ] — single press toggle: real game hitbox ↔ expanded hitbox
        toggleOriginalHitbox()
    elseif input.KeyCode == Enum.KeyCode.M then
        -- M — PC only. Toggle Mouse Camlock. Left-click then acquires target under cursor.
        if not IS_MOBILE then
            triplePress("m_key", function()
                getgenv().MouseCamlockEnabled = not getgenv().MouseCamlockEnabled
                notify("Mouse Camlock", getgenv().MouseCamlockEnabled and "ON — click to lock" or "OFF", 2)
            end)
        end
    elseif input.KeyCode == Enum.KeyCode.Z then
        triplePress("z_key", function()
            getgenv().WallCheckEnabled = not getgenv().WallCheckEnabled
            updateZBtn()
        end)
    elseif input.KeyCode == Enum.KeyCode.J then
        triplePress("j_key", function()
            whitelistGui.Visible = not whitelistGui.Visible
        end)
    elseif input.KeyCode == Enum.KeyCode.K then
        triplePress("k_key", function()
            autoLockGui.Visible = not autoLockGui.Visible
        end)
    elseif input.KeyCode == Enum.KeyCode.P then
        local now = tick()
        if (now - pLastPress) > TRIPLE_PRESS_WINDOW then
            pPressCount = 1
        else
            pPressCount = pPressCount + 1
        end
        pLastPress = now

        if pPressCount >= 3 then
            pPressCount = 0
            toggleSafeMode()
        end
    end
end)

-- =============================================
-- PLAYER SETUP
-- =============================================
local function setupPlayer(player)
    if player == LocalPlayer then return end
    if player.Character then
        task.wait(0.5)
        applyHitbox(player)
        setupHealthWatch(player)
    end
    player.CharacterAdded:Connect(function()
        task.wait(0.5)
        applyHitbox(player)
        setupHealthWatch(player)
        local uid = player.UserId
        trackingState[uid]       = nil
        anomalyCache[uid]        = nil
        lockedPartName[uid]      = nil
        lastPartCycleTime[uid]   = nil
        partCycleIndex[uid]      = nil
        prevLockedPartName[uid]  = nil
        partTransitionStart[uid] = nil
        originalPartSizes[uid]   = nil  -- re-capture actual size on next applyHitbox
    end)
end

Players.PlayerAdded:Connect(function(player)
    setupPlayer(player)
    rebuildWhitelistGui()
    rebuildAutoLockGui()
end)

for _, player in ipairs(Players:GetPlayers()) do setupPlayer(player) end

Players.PlayerRemoving:Connect(function(player)
    local userId = player.UserId
    if connections[userId] then
        for _, conn in ipairs(connections[userId]) do conn:Disconnect() end
        connections[userId] = nil
    end
    if healthConnections[userId] then
        healthConnections[userId]:Disconnect()
        healthConnections[userId] = nil
    end
    pendingRelock[userId]       = nil
    trackingState[userId]       = nil
    anomalyCache[userId]        = nil
    lockedPartName[userId]      = nil
    lastPartCycleTime[userId]   = nil
    partCycleIndex[userId]      = nil
    prevLockedPartName[userId]  = nil
    partTransitionStart[userId] = nil
    originalPartSizes[userId]   = nil
    notifiedCarries[userId] = nil
    getgenv().Whitelist[userId] = nil
    if getgenv().CamlockTarget == player then releaseTarget() end
    rebuildWhitelistGui()
    rebuildAutoLockGui()
end)

task.spawn(function()
    while true do
        task.wait(5)
        validateHitboxes()
    end
end)

rebuildWhitelistGui()
rebuildAutoLockGui()
updateXBtn(false)
updateCBtn()
updateZBtn()
updateBracketBtn()
notify("Demigod 🌟", "Mode: " .. getgenv().ScriptMode .. " | C: Lock | V: Hitbox Vis | Z: Wall | ]: Expander OFF | J: Whitelist | K: Auto-Lock | P x3: Safe Mode", 6)
print("Demigod script loaded — Mode: " .. getgenv().ScriptMode)
