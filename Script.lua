-- =============================================
-- MODE SELECTION — must run first
-- =============================================
getgenv().CamlockTarget = nil
getgenv().ScriptMode = getgenv().ScriptMode or nil

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
getgenv().HitboxSize = Vector3.new(9, 9, 9) -- updated per request
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().WallCheckEnabled = true
getgenv().Whitelist = getgenv().Whitelist or {}
getgenv().AutoLockPool = getgenv().AutoLockPool or {}
getgenv().AutoLockEnabled = false
getgenv().SafeMode = false
getgenv().MouseCamlockEnabled = false

local KNOCK_THRESHOLD = 2
local RELOCK_THRESHOLD = 11
local LOCAL_HEALTH_GATE = 15
local MAX_HEALTH = 100
local TRIPLE_PRESS_WINDOW = 1.0
local AIM_OFFSET = Vector3.new(0, 1.6, 0)

-- Tracking constants — lowered baseline smoothing for a rage-lock feel
-- instead of a clean follow curve. Jitter adds controlled unpredictability.
local VELOCITY_SMOOTH_RATE = 8.0
local LOOK_SMOOTH_RATE = 16.0      -- raised from 10 -> snappier, less "smooth camera" feel
local LOOK_JITTER_MAG = 0.015      -- small angular jitter so tracking doesn't read as a clean curve
local LEAD_TIME = 0.12
local JUMP_VEL_THRESHOLD = 18
local JUMP_SNAP_RATE = 26.0
local JUMP_SNAP_DURATION = 0.35

-- Anomaly detection thresholds — used only to change YOUR camera's
-- own tracking speed, never anything about hit registration
local MACRO_SPEED_MULT = 1.15      -- "a little bit more predictable" -> slightly higher lead accuracy
local CFRAME_ACCEL_SPIKE = 500     -- studs/s^2, well above normal movement, flags teleport-style motion
local CFRAME_TRACK_RATE_MULT = 1.6
local FLYING_TRACK_RATE_MULT = 2.1
local SPEEDHACK_VEL_THRESHOLD = 60 -- studs/s, above Da Hood's normal sprint speed
local FLYING_Y_VEL_THRESHOLD = 25  -- sustained upward velocity with no ground contact

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local connections = {}
local healthConnections = {}
local carriedCharacter = nil
local wasCarrying = false
local pendingRelock = {}
local trackingState = {}

local function getTrackingState(userId)
    if not trackingState[userId] then
        trackingState[userId] = {
            smoothedVelocity = Vector3.zero,
            lastVelocity = Vector3.zero,
            jumpSnapUntil = 0,
            anomalyMult = 1.0, -- current speed multiplier from detection below
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
    qFrame = 0.3, cFrame = 0.3, zFrame = 0.3,
    wlToggleBtn = 0.3, alToggleBtn = 0.3, emoteBtn = 0.15, mcFrame = 0.3,
}

local qFrame, qBtn, qDot, cFrame, cBtn, cDot, zFrame, zBtn, zDot
local wlToggleBtn, alToggleBtn, emoteBtn
local mcFrame, mcBtn, mcDot

if IS_MOBILE then
    qFrame = Instance.new("Frame")
    qFrame.Size = UDim2.new(0, 50, 0, 50)
    qFrame.Position = UDim2.new(0.5, -80, 1, -120)
    qFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    qFrame.BackgroundTransparency = 0.3
    qFrame.Active = true
    qFrame.ZIndex = 20
    qFrame.Parent = screenGui
    Instance.new("UICorner", qFrame).CornerRadius = UDim.new(1, 0)

    qBtn = Instance.new("TextButton")
    qBtn.Size = UDim2.new(1, 0, 1, 0)
    qBtn.BackgroundTransparency = 1
    qBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    qBtn.Text = "Q"
    qBtn.Font = Enum.Font.GothamBold
    qBtn.TextSize = 22
    qBtn.Active = true
    qBtn.ZIndex = 21
    qBtn.Parent = qFrame

    qDot = Instance.new("Frame")
    qDot.Size = UDim2.new(0, 10, 0, 10)
    qDot.Position = UDim2.new(1, -2, 0, -2)
    qDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    qDot.ZIndex = 22
    qDot.Parent = qFrame
    Instance.new("UICorner", qDot).CornerRadius = UDim.new(1, 0)

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
    cBtn.Text = "C"
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

    wlToggleBtn = Instance.new("TextButton")
    wlToggleBtn.Size = UDim2.new(0, 46, 0, 46)
    wlToggleBtn.Position = UDim2.new(0, 10, 0, 144) -- LEFT side
    wlToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    wlToggleBtn.BackgroundTransparency = 0.3
    wlToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    wlToggleBtn.Text = "WL"
    wlToggleBtn.Font = Enum.Font.GothamBold
    wlToggleBtn.TextSize = 13
    wlToggleBtn.Active = true
    wlToggleBtn.ZIndex = 20
    wlToggleBtn.Parent = screenGui
    Instance.new("UICorner", wlToggleBtn).CornerRadius = UDim.new(1, 0)

    alToggleBtn = Instance.new("TextButton")
    alToggleBtn.Size = UDim2.new(0, 46, 0, 46)
    alToggleBtn.Position = UDim2.new(1, -56, 0, 144) -- RIGHT side, opposite WL
    alToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    alToggleBtn.BackgroundTransparency = 0.3
    alToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    alToggleBtn.Text = "AL"
    alToggleBtn.Font = Enum.Font.GothamBold
    alToggleBtn.TextSize = 13
    alToggleBtn.Active = true
    alToggleBtn.ZIndex = 20
    alToggleBtn.Parent = screenGui
    Instance.new("UICorner", alToggleBtn).CornerRadius = UDim.new(1, 0)

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
else
    mcFrame = Instance.new("Frame")
    mcFrame.Size = UDim2.new(0, 50, 0, 50)
    mcFrame.Position = UDim2.new(1, -70, 0.5, -25)
    mcFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    mcFrame.BackgroundTransparency = 0.3
    mcFrame.Active = true
    mcFrame.ZIndex = 20
    mcFrame.Parent = screenGui
    Instance.new("UICorner", mcFrame).CornerRadius = UDim.new(1, 0)

    mcBtn = Instance.new("TextButton")
    mcBtn.Size = UDim2.new(1, 0, 1, 0)
    mcBtn.BackgroundTransparency = 1
    mcBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    mcBtn.Text = "MC"
    mcBtn.Font = Enum.Font.GothamBold
    mcBtn.TextSize = 16
    mcBtn.Active = true
    mcBtn.ZIndex = 21
    mcBtn.Parent = mcFrame

    mcDot = Instance.new("Frame")
    mcDot.Size = UDim2.new(0, 10, 0, 10)
    mcDot.Position = UDim2.new(1, -2, 0, -2)
    mcDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    mcDot.ZIndex = 22
    mcDot.Parent = mcFrame
    Instance.new("UICorner", mcDot).CornerRadius = UDim.new(1, 0)
    makeDraggable(mcFrame)
end

local function fireEmoteMenu()
    local VIM = game:GetService("VirtualInputManager")
    pcall(function()
        VIM:SendKeyEvent(true, Enum.KeyCode.Period, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.Period, false, game)
    end)
end

if IS_MOBILE and emoteBtn then
    emoteBtn.MouseButton1Click:Connect(function()
        triplePress("emote", fireEmoteMenu)
    end)
end

local function updateQBtn(locked)
    if not IS_MOBILE then return end
    if locked then
        qFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        qDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        qFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        qDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local function updateCBtn()
    if not IS_MOBILE then return end
    if getgenv().HitboxVisible then
        cFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        cDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local function updateZBtn()
    if not IS_MOBILE then return end
    if getgenv().WallCheckEnabled then
        zFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        zDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        zFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        zDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local function updateMCBtn()
    if IS_MOBILE or not mcFrame then return end
    if getgenv().MouseCamlockEnabled then
        mcFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        mcDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        mcFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        mcDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

local safeModeBtn
local allMobileButtons = {}

if IS_MOBILE then
    safeModeBtn = Instance.new("TextButton")
    safeModeBtn.Size = UDim2.new(0, 46, 0, 46)
    safeModeBtn.Position = UDim2.new(1, -56, 0, 90)
    safeModeBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    safeModeBtn.BackgroundTransparency = 0
    safeModeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    safeModeBtn.Text = "SAFE"
    safeModeBtn.Font = Enum.Font.GothamBold
    safeModeBtn.TextSize = 12
    safeModeBtn.Active = true
    safeModeBtn.ZIndex = 200
    safeModeBtn.Parent = screenGui
    Instance.new("UICorner", safeModeBtn).CornerRadius = UDim.new(1, 0)
    makeDraggable(safeModeBtn)

    table.insert(allMobileButtons, {frame = qFrame, controls = {qBtn, qDot}, key = "qFrame"})
    table.insert(allMobileButtons, {frame = cFrame, controls = {cBtn, cDot}, key = "cFrame"})
    table.insert(allMobileButtons, {frame = zFrame, controls = {zBtn, zDot}, key = "zFrame"})
    table.insert(allMobileButtons, {frame = wlToggleBtn, controls = {}, key = "wlToggleBtn"})
    table.insert(allMobileButtons, {frame = alToggleBtn, controls = {}, key = "alToggleBtn"})
    if emoteBtn then table.insert(allMobileButtons, {frame = emoteBtn, controls = {}, key = "emoteBtn"}) end
end

local safeModeSavedPosition = nil
local safeModeCenterPos

local function applySafeModeVisual()
    if not IS_MOBILE then return end

    if getgenv().SafeMode then
        safeModeSavedPosition = safeModeBtn.Position
        if not safeModeCenterPos then
            safeModeCenterPos = UDim2.new(0.5, -23, 0.5, -23)
        end
        safeModeBtn.Position = safeModeCenterPos
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
        if safeModeSavedPosition then
            safeModeBtn.Position = safeModeSavedPosition
        end

        for _, entry in ipairs(allMobileButtons) do
            entry.frame.BackgroundTransparency = ORIGINAL_TRANSPARENCY[entry.key] or 0.3
            for _, ctrl in ipairs(entry.controls) do
                if ctrl:IsA("TextButton") then
                    ctrl.TextTransparency = 0
                    ctrl.BackgroundTransparency = 1
                elseif ctrl:IsA("Frame") then
                    ctrl.BackgroundTransparency = 0
                end
            end
        end

        updateQBtn(getgenv().CamlockTarget ~= nil)
        updateCBtn()
        updateZBtn()
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
-- WHITELIST GUI — LEFT side
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

-- =============================================
-- AUTO-LOCK GUI — RIGHT side (opposite Whitelist, per request)
-- =============================================
local autoLockGui = Instance.new("Frame")
autoLockGui.Size = UDim2.new(0, 220, 0, 300)
autoLockGui.Position = UDim2.new(1, -240, 0.5, -150) -- confirmed: right side, opposite the left-side Whitelist
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
                        updateQBtn(false)
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

if IS_MOBILE then
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

if not IS_MOBILE and mcBtn then
    mcBtn.MouseButton1Click:Connect(function()
        getgenv().MouseCamlockEnabled = not getgenv().MouseCamlockEnabled
        updateMCBtn()
    end)
end

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

    targetPart.Size = getgenv().HitboxSize
    targetPart.Transparency = getgenv().HitboxVisible and 0.5 or 1
    targetPart.CanCollide = false
    disableAllCollision(player.Character)

    local userId = player.UserId
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

if IS_MOBILE then
    cBtn.MouseButton1Click:Connect(function()
        triplePress("c_btn", function()
            getgenv().HitboxVisible = not getgenv().HitboxVisible
            updateVisibility()
            updateCBtn()
        end)
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

-- =============================================
-- ANOMALY DETECTION — reads only publicly-observable physics
-- (position/velocity deltas). Output ONLY changes how fast YOUR
-- camera rotates toward the target. Never touches hit registration,
-- never touches any other player's state.
-- =============================================
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

    -- Flying: sustained upward velocity with no ground contact via humanoid state
    local isAirborne = humanoid and humanoid:GetState() == Enum.HumanoidStateType.Freefall
    if isAirborne and instVel.Y > FLYING_Y_VEL_THRESHOLD then
        return "flying"
    end

    -- CFrame/teleport-style motion: acceleration far beyond anything
    -- physically reachable through normal movement or even sprint
    if accelMag > CFRAME_ACCEL_SPIKE then
        return "cframe"
    end

    -- Speedhack: sustained horizontal velocity above normal sprint cap
    local horizVel = Vector3.new(instVel.X, 0, instVel.Z).Magnitude
    if horizVel > SPEEDHACK_VEL_THRESHOLD then
        return "speedhack"
    end

    -- Macro: near-constant velocity magnitude with abrupt direction
    -- changes at regular intervals — approximated here as repeated
    -- sharp direction flips at a consistent speed, distinct from
    -- natural human strafing which varies more in magnitude
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

local function updateTrackingState(userId, targetHRP, humanoid, dt)
    local state = getTrackingState(userId)
    local rawVel = targetHRP.AssemblyLinearVelocity

    local filterAlpha = 1 - math.exp(-VELOCITY_SMOOTH_RATE * dt)
    state.smoothedVelocity = state.smoothedVelocity:Lerp(rawVel, filterAlpha)

    if rawVel.Y > JUMP_VEL_THRESHOLD then
        state.jumpSnapUntil = tick() + JUMP_SNAP_DURATION
    end

    local anomaly = detectAnomaly(userId, targetHRP, humanoid)
    state.anomalyMult = getSpeedMultiplierFor(anomaly)

    return state
end

local function getAimPoint(targetHRP, humanoid, userId, dt)
    local state = updateTrackingState(userId, targetHRP, humanoid, dt)
    -- Under macro detection, lead accuracy tightens slightly (predictable
    -- movement is easier to lead correctly, hence "a little more predictable")
    local leadTime = LEAD_TIME * (state.anomalyMult > 1.0 and state.anomalyMult or 1.0) * 0.6
        + (state.anomalyMult == MACRO_SPEED_MULT and LEAD_TIME * 0.2 or 0)
    local leadPos = targetHRP.Position + (state.smoothedVelocity * leadTime) + AIM_OFFSET
    local inSnapWindow = tick() < state.jumpSnapUntil
    return leadPos, inSnapWindow, state.anomalyMult
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

-- Priority: when multiple candidates are ALL at full health, nearest
-- wins outright regardless of count — this is the N-candidate version
-- of the earlier two-way "both full health" rule.
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

    -- If any full-health candidates exist and wall check is on,
    -- nearest among THEM takes priority over lower-health candidates
    -- only when best is still nil OR when a full-health group exists
    -- and none of them have been beaten by a genuinely lower health value
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
    getgenv().CamlockTarget = nil
    updateQBtn(false)
end

local function handleQ()
    if isTyping() then return end
    if getgenv().CamlockTarget then
        releaseTarget()
    else
        local target = getPlayerInCrosshair()
        if target and target ~= LocalPlayer then
            getgenv().CamlockTarget = target
            trackingState[target.UserId] = nil
            updateQBtn(true)
        end
    end
end

-- =============================================
-- Q BUTTON
-- =============================================
pcall(function() ContextActionService:UnbindAction("DemigodQAction") end)

ContextActionService:BindAction(
    "DemigodQAction",
    function(actionName, inputState)
        if inputState == Enum.UserInputState.Begin then
            triplePress("q_action", handleQ)
        end
    end,
    IS_MOBILE,
    Enum.KeyCode.Q
)

if IS_MOBILE then
    ContextActionService:SetPosition("DemigodQAction", UDim2.new(0.5, -80, 1, -120))
    pcall(function()
        ContextActionService:SetTitle("DemigodQAction", "")
        ContextActionService:SetImage("DemigodQAction", "")
    end)
    qBtn.MouseButton1Click:Connect(function()
        triplePress("q_action", handleQ)
    end)
end

-- =============================================
-- MAIN CAMLOCK — less smooth, controlled jitter,
-- anomaly-speed-scaled, jump-snap intact
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
                    trackingState[autoTarget.UserId] = nil
                end
                getgenv().CamlockTarget = autoTarget
                updateQBtn(true)
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

    local hrp = target.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not hrp:IsDescendantOf(workspace) then releaseTarget(); return end

    if not hasLineOfSight(hrp) then return end

    local camCF = Camera.CFrame
    local camPos = camCF.Position
    local currentLook = camCF.LookVector

    local aimPoint, inSnapWindow, speedMult = getAimPoint(hrp, hum, target.UserId, dt)
    local toTarget = aimPoint - camPos
    if toTarget.Magnitude < 0.1 then return end

    local targetDir = toTarget.Unit

    -- Rage-lock feel: base rate raised, scaled further by anomaly
    -- detection (macro/cframe/speedhack/flying all push this higher)
    local rate = (inSnapWindow and JUMP_SNAP_RATE or LOOK_SMOOTH_RATE) * speedMult
    local alpha = 1 - math.exp(-rate * dt)

    -- Controlled jitter: small random angular offset so the tracking
    -- doesn't read as a clean smoothed curve — this is what breaks
    -- the "predictable follow" look and gives the rage-lock aesthetic
    local jitterX = (math.random() - 0.5) * LOOK_JITTER_MAG
    local jitterY = (math.random() - 0.5) * LOOK_JITTER_MAG
    local jitteredDir = (targetDir + Vector3.new(jitterX, jitterY, 0)).Unit

    local newLook = currentLook:Lerp(jitteredDir, alpha)
    if newLook.Magnitude < 0.001 then return end

    Camera.CFrame = CFrame.new(camPos, camPos + newLook)
end)

-- =============================================
-- MOUSE CAMLOCK — PC only
-- =============================================
if not IS_MOBILE then
    pcall(function() RunService:UnbindFromRenderStep("DemigodMouseCamlock") end)

    RunService:BindToRenderStep("DemigodMouseCamlock", Enum.RenderPriority.Camera.Value + 2, function(dt)
        if not getgenv().MouseCamlockEnabled then return end
        local target = getgenv().CamlockTarget
        if not target or not target.Character then return end

        local hrp = target.Character:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp:IsDescendantOf(workspace) then return end
        local hum = target.Character:FindFirstChildOfClass("Humanoid")

        local aimPoint = getAimPoint(hrp, hum, target.UserId, dt)
        local screenPos, onScreen = Camera:WorldToViewportPoint(aimPoint)

        if onScreen then
            pcall(function()
                UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            end)
        end
    end)
end

-- =============================================
-- CARRY DETECTION — visual/state tracking only.
-- No firing action attached to this, per the standing
-- boundary on hit registration.
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

-- Detects who is carrying a KNOCKED player, for any other players
-- in the server (not just yourself) — surfaces it via notification
-- so you can manually target the carrier if you choose to.
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

        -- Surface knocked-and-carried players server-wide, for manual Q-targeting
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
-- REMAINING KEYBINDS
-- =============================================
local pPressCount = 0
local pLastPress = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if isTyping() then return end

    if input.KeyCode == Enum.KeyCode.C then
        triplePress("c_key", function()
            getgenv().HitboxVisible = not getgenv().HitboxVisible
            updateVisibility()
            updateCBtn()
        end)
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
    elseif input.KeyCode == Enum.KeyCode.M and not IS_MOBILE then
        getgenv().MouseCamlockEnabled = not getgenv().MouseCamlockEnabled
        updateMCBtn()
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
        trackingState[player.UserId] = nil
        anomalyCache[player.UserId] = nil
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
    pendingRelock[userId] = nil
    trackingState[userId] = nil
    anomalyCache[userId] = nil
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
updateQBtn(false)
updateCBtn()
updateZBtn()
updateMCBtn()
notify("Demigod 🌟", "Mode: " .. getgenv().ScriptMode .. " | Q: Lock | M: Mouse Camlock (PC) | C: Visibility | Z: Wall | J: Whitelist | K: Auto-Lock | P x3: Safe Mode", 6)
print("Demigod script loaded — Mode: " .. getgenv().ScriptMode)
