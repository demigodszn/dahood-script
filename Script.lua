-- =============================================
-- MODE SELECTION — must run first
-- =============================================
getgenv().ScriptMode = getgenv().ScriptMode or nil -- "PC" or "Mobile"

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
getgenv().HitboxSize = Vector3.new(8, 8, 8)
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().CamlockTarget = nil
getgenv().WallCheckEnabled = false
getgenv().Whitelist = getgenv().Whitelist or {}
getgenv().AutoLockPool = getgenv().AutoLockPool or {}
getgenv().AutoLockEnabled = false

local SMOOTHNESS = 0.095
local AIM_OFFSET = Vector3.new(0, 1.6, 0)
local PING_MIN = 0.059
local PING_MAX = 0.080
local KNOCK_THRESHOLD = 2

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local connections = {}
local healthConnections = {}
local lastVelocityCache = {}
local carriedCharacter = nil
local wasCarrying = false

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 3})
    end)
end

local function isTyping()
    return UserInputService:GetFocusedTextBox() ~= nil
end

-- =============================================
-- MAIN GUI SETUP
-- =============================================
local existingGui = LocalPlayer.PlayerGui:FindFirstChild("DemigodGui")
if existingGui then existingGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DemigodGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = LocalPlayer.PlayerGui

local qFrame, qBtn, qDot, cFrame, cBtn, cDot
local wlToggleBtn, alToggleBtn

if IS_MOBILE then
    qFrame = Instance.new("Frame")
    qFrame.Size = UDim2.new(0, 50, 0, 50)
    qFrame.Position = UDim2.new(0.5, -55, 1, -120)
    qFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    qFrame.BackgroundTransparency = 0.3
    qFrame.Active = true
    qFrame.Parent = screenGui
    Instance.new("UICorner", qFrame).CornerRadius = UDim.new(1, 0)

    qBtn = Instance.new("TextButton")
    qBtn.Size = UDim2.new(1, 0, 1, 0)
    qBtn.BackgroundTransparency = 1
    qBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    qBtn.Text = "Q"
    qBtn.Font = Enum.Font.GothamBold
    qBtn.TextSize = 22
    qBtn.Parent = qFrame

    qDot = Instance.new("Frame")
    qDot.Size = UDim2.new(0, 10, 0, 10)
    qDot.Position = UDim2.new(1, -2, 0, -2)
    qDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    qDot.Parent = qFrame
    Instance.new("UICorner", qDot).CornerRadius = UDim.new(1, 0)

    cFrame = Instance.new("Frame")
    cFrame.Size = UDim2.new(0, 50, 0, 50)
    cFrame.Position = UDim2.new(0.5, 5, 1, -120)
    cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    cFrame.BackgroundTransparency = 0.3
    cFrame.Active = true
    cFrame.Parent = screenGui
    Instance.new("UICorner", cFrame).CornerRadius = UDim.new(1, 0)

    cBtn = Instance.new("TextButton")
    cBtn.Size = UDim2.new(1, 0, 1, 0)
    cBtn.BackgroundTransparency = 1
    cBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    cBtn.Text = "C"
    cBtn.Font = Enum.Font.GothamBold
    cBtn.TextSize = 22
    cBtn.Parent = cFrame

    cDot = Instance.new("Frame")
    cDot.Size = UDim2.new(0, 10, 0, 10)
    cDot.Position = UDim2.new(1, -2, 0, -2)
    cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    cDot.Parent = cFrame
    Instance.new("UICorner", cDot).CornerRadius = UDim.new(1, 0)

    wlToggleBtn = Instance.new("TextButton")
    wlToggleBtn.Size = UDim2.new(0, 50, 0, 50)
    wlToggleBtn.Position = UDim2.new(0.5, -55, 1, -180)
    wlToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    wlToggleBtn.BackgroundTransparency = 0.3
    wlToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    wlToggleBtn.Text = "WL"
    wlToggleBtn.Font = Enum.Font.GothamBold
    wlToggleBtn.TextSize = 14
    wlToggleBtn.Parent = screenGui
    Instance.new("UICorner", wlToggleBtn).CornerRadius = UDim.new(1, 0)

    alToggleBtn = Instance.new("TextButton")
    alToggleBtn.Size = UDim2.new(0, 50, 0, 50)
    alToggleBtn.Position = UDim2.new(0.5, 5, 1, -180)
    alToggleBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    alToggleBtn.BackgroundTransparency = 0.3
    alToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    alToggleBtn.Text = "AL"
    alToggleBtn.Font = Enum.Font.GothamBold
    alToggleBtn.TextSize = 14
    alToggleBtn.Parent = screenGui
    Instance.new("UICorner", alToggleBtn).CornerRadius = UDim.new(1, 0)
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

-- =============================================
-- WHITELIST GUI — keybind J
-- =============================================
local whitelistGui = Instance.new("Frame")
whitelistGui.Size = UDim2.new(0, 220, 0, 300)
whitelistGui.Position = UDim2.new(0, 20, 0.5, -150)
whitelistGui.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
whitelistGui.Visible = false
whitelistGui.Active = true
whitelistGui.Parent = screenGui
Instance.new("UICorner", whitelistGui).CornerRadius = UDim.new(0, 8)

local wlTitle = Instance.new("TextLabel")
wlTitle.Size = UDim2.new(1, 0, 0, 30)
wlTitle.BackgroundTransparency = 1
wlTitle.Text = "Whitelist"
wlTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
wlTitle.Font = Enum.Font.GothamBold
wlTitle.TextSize = 16
wlTitle.Parent = whitelistGui

local wlScroll = Instance.new("ScrollingFrame")
wlScroll.Size = UDim2.new(1, -10, 1, -40)
wlScroll.Position = UDim2.new(0, 5, 0, 32)
wlScroll.BackgroundTransparency = 1
wlScroll.ScrollBarThickness = 4
wlScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
wlScroll.Parent = whitelistGui

local wlLayout = Instance.new("UIListLayout")
wlLayout.Padding = UDim.new(0, 4)
wlLayout.Parent = wlScroll

-- =============================================
-- AUTO-LOCK GUI — keybind K
-- Rows toggle POOL membership (stackable), not a
-- single pick. Selected players all join one active
-- rotation governed by health/distance priority.
-- =============================================
local autoLockGui = Instance.new("Frame")
autoLockGui.Size = UDim2.new(0, 220, 0, 300)
autoLockGui.Position = UDim2.new(1, -240, 0.5, -150)
autoLockGui.BackgroundColor3 = Color3.fromRGB(30, 40, 30)
autoLockGui.Visible = false
autoLockGui.Active = true
autoLockGui.Parent = screenGui
Instance.new("UICorner", autoLockGui).CornerRadius = UDim.new(0, 8)

local alTitle = Instance.new("TextLabel")
alTitle.Size = UDim2.new(1, 0, 0, 30)
alTitle.BackgroundTransparency = 1
alTitle.Text = "Auto-Lock"
alTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
alTitle.Font = Enum.Font.GothamBold
alTitle.TextSize = 16
alTitle.Parent = autoLockGui

local alEnableBtn = Instance.new("TextButton")
alEnableBtn.Size = UDim2.new(1, -10, 0, 28)
alEnableBtn.Position = UDim2.new(0, 5, 0, 32)
alEnableBtn.BackgroundColor3 = Color3.fromRGB(90, 80, 60)
alEnableBtn.Text = "Auto-Lock: OFF"
alEnableBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
alEnableBtn.Font = Enum.Font.GothamBold
alEnableBtn.TextSize = 12
alEnableBtn.Parent = autoLockGui
Instance.new("UICorner", alEnableBtn).CornerRadius = UDim.new(0, 6)

local alScroll = Instance.new("ScrollingFrame")
alScroll.Size = UDim2.new(1, -10, 1, -70)
alScroll.Position = UDim2.new(0, 5, 0, 64)
alScroll.BackgroundTransparency = 1
alScroll.ScrollBarThickness = 4
alScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
alScroll.Parent = autoLockGui

local alLayout = Instance.new("UIListLayout")
alLayout.Padding = UDim.new(0, 4)
alLayout.Parent = alScroll

local function clearChildren(parent)
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
end

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
            row.Parent = wlScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

            row.MouseButton1Click:Connect(function()
                getgenv().Whitelist[player.UserId] = not getgenv().Whitelist[player.UserId] or nil
                rebuildWhitelistGui()
            end)
        end
    end
    wlScroll.CanvasSize = UDim2.new(0, 0, 0, wlLayout.AbsoluteContentSize.Y + 10)
end

local function rebuildAutoLockGui()
    clearChildren(alScroll)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 30)
            row.BackgroundColor3 = getgenv().AutoLockPool[player.UserId]
                and Color3.fromRGB(60, 120, 60)
                or Color3.fromRGB(50, 50, 60)
            row.Text = player.Name .. (getgenv().AutoLockPool[player.UserId] and " ✓ (pooled)" or "")
            row.TextColor3 = Color3.fromRGB(255, 255, 255)
            row.Font = Enum.Font.Gotham
            row.TextSize = 12
            row.Parent = alScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

            row.MouseButton1Click:Connect(function()
                getgenv().AutoLockPool[player.UserId] = not getgenv().AutoLockPool[player.UserId] or nil
                rebuildAutoLockGui()
            end)
        end
    end
    alScroll.CanvasSize = UDim2.new(0, 0, 0, alLayout.AbsoluteContentSize.Y + 10)
end

alEnableBtn.MouseButton1Click:Connect(function()
    getgenv().AutoLockEnabled = not getgenv().AutoLockEnabled
    alEnableBtn.Text = "Auto-Lock: " .. (getgenv().AutoLockEnabled and "ON" or "OFF")
    alEnableBtn.BackgroundColor3 = getgenv().AutoLockEnabled
        and Color3.fromRGB(60, 120, 60)
        or Color3.fromRGB(90, 80, 60)
end)

if IS_MOBILE then
    wlToggleBtn.MouseButton1Click:Connect(function()
        whitelistGui.Visible = not whitelistGui.Visible
    end)
    alToggleBtn.MouseButton1Click:Connect(function()
        autoLockGui.Visible = not autoLockGui.Visible
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
        getgenv().HitboxVisible = not getgenv().HitboxVisible
        updateVisibility()
        updateCBtn()
    end)
end

-- =============================================
-- CAMLOCK CORE
-- =============================================
local function isKnockedOrDead(player)
    if not player or not player.Character then return true end
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return true end
    local ok, health = pcall(function() return humanoid.Health end)
    if not ok then return true end
    return health <= KNOCK_THRESHOLD
end

local function hasLineOfSight(targetHRP)
    if not getgenv().WallCheckEnabled then return true end
    local localChar = LocalPlayer.Character
    if not localChar then return false end
    local origin = Camera.CFrame.Position
    local direction = targetHRP.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {localChar, targetHRP.Parent}
    return workspace:Raycast(origin, direction.Unit * direction.Magnitude, params) == nil
end

local function getAcceleration(player, velocity)
    local userId = player.UserId
    local now = tick()
    if not lastVelocityCache[userId] then
        lastVelocityCache[userId] = {velocity = velocity, time = now}
        return Vector3.zero
    end
    local cached = lastVelocityCache[userId]
    local dt = now - cached.time
    if dt <= 0 then return Vector3.zero end
    local accel = (velocity - cached.velocity) / dt
    lastVelocityCache[userId] = {velocity = velocity, time = now}
    return accel
end

local function getPredictedPosition(targetHRP, player)
    local ping = math.clamp(LocalPlayer:GetNetworkPing(), PING_MIN, PING_MAX)
    local vel = targetHRP.AssemblyLinearVelocity
    local accel = getAcceleration(player, vel)
    local ca = Vector3.new(
        math.clamp(accel.X, -80, 80),
        math.clamp(accel.Y, -80, 80),
        math.clamp(accel.Z, -80, 80)
    )
    return targetHRP.Position + vel * ping + 0.5 * ca * ping * ping + AIM_OFFSET
end

local function getPlayerInCrosshair()
    local best, bestDot = nil, -math.huge
    local look = Camera.CFrame.LookVector
    local camPos = Camera.CFrame.Position

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not getgenv().Whitelist[player.UserId] and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hrp and hrp:IsDescendantOf(workspace) and not isKnockedOrDead(player) then
                if not getgenv().WallCheckEnabled or hasLineOfSight(hrp) then
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

-- Auto-Lock: evaluates the whole stacked pool every frame.
-- Priority = lowest health wins; distance only breaks a tie.
-- Dead/knocked/left players are removed from the pool here,
-- so the pool self-cleans as fights resolve.
local function getAutoLockTarget()
    local best, bestHealth, bestDist = nil, math.huge, math.huge
    local localChar = LocalPlayer.Character
    local localHRP = localChar and localChar:FindFirstChild("HumanoidRootPart")
    if not localHRP then return nil end

    for userId in pairs(getgenv().AutoLockPool) do
        local player = Players:GetPlayerByUserId(userId)
        if player and player ~= LocalPlayer and not getgenv().Whitelist[userId] and player.Character then
            local hum = player.Character:FindFirstChildOfClass("Humanoid")
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")

            if hum and hrp and hrp:IsDescendantOf(workspace) then
                local ok, health = pcall(function() return hum.Health end)

                if ok and health > KNOCK_THRESHOLD then
                    if not getgenv().WallCheckEnabled or hasLineOfSight(hrp) then
                        local dist = (hrp.Position - localHRP.Position).Magnitude
                        if health < bestHealth or (health == bestHealth and dist < bestDist) then
                            bestHealth = health
                            bestDist = dist
                            best = player
                        end
                    end
                else
                    getgenv().AutoLockPool[userId] = nil -- dead/knocked, drop from pool
                end
            else
                getgenv().AutoLockPool[userId] = nil -- character gone, drop from pool
            end
        end
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
            updateQBtn(true)
        end
    end
end

if IS_MOBILE then
    qBtn.MouseButton1Click:Connect(handleQ)
end

Camera.CameraType = Enum.CameraType.Custom
pcall(function() RunService:UnbindFromRenderStep("DemigodCamlock") end)

RunService:BindToRenderStep("DemigodCamlock", Enum.RenderPriority.Camera.Value + 1, function(dt)
    -- Auto-Lock drives targeting continuously while the pool is non-empty.
    -- It takes priority over manual Q selection while active.
    if getgenv().AutoLockEnabled and next(getgenv().AutoLockPool) ~= nil then
        local autoTarget = getAutoLockTarget()
        if autoTarget then
            getgenv().CamlockTarget = autoTarget
            updateQBtn(true)
        elseif getgenv().CamlockTarget then
            releaseTarget()
        end
    end

    local target = getgenv().CamlockTarget
    if not target then return end

    if target == LocalPlayer then releaseTarget(); return end
    if getgenv().Whitelist[target.UserId] then releaseTarget(); return end

    if not target.Character then releaseTarget(); return end

    local hum = target.Character:FindFirstChildOfClass("Humanoid")
    if not hum then releaseTarget(); return end

    local ok, health = pcall(function() return hum.Health end)
    if not ok or health <= KNOCK_THRESHOLD then releaseTarget(); return end

    local hrp = target.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not hrp:IsDescendantOf(workspace) then releaseTarget(); return end

    if getgenv().WallCheckEnabled and not hasLineOfSight(hrp) then return end

    local camCF = Camera.CFrame
    local camPos = camCF.Position
    local currentLook = camCF.LookVector

    local predicted = getPredictedPosition(hrp, target)
    local toTarget = predicted - camPos
    if toTarget.Magnitude < 0.1 then return end

    local targetDir = toTarget.Unit
    local dot = currentLook:Dot(targetDir)

    local closeness = math.clamp((dot - 0.9) / 0.1, 0, 1)
    local baseAlpha = 1 - (1 - SMOOTHNESS) ^ (dt * 60)
    local alpha = baseAlpha + (1 - baseAlpha) * closeness * 0.6

    local newLook = currentLook:Lerp(targetDir, alpha)
    if newLook.Magnitude < 0.001 then return end

    Camera.CFrame = CFrame.new(camPos, camPos + newLook)
end)

-- =============================================
-- CARRY DETECTION
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

task.spawn(function()
    while true do
        task.wait(0.1)
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
-- KEYBINDS
-- =============================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if isTyping() then return end

    if input.KeyCode == Enum.KeyCode.Q then
        handleQ()
    elseif input.KeyCode == Enum.KeyCode.C then
        getgenv().HitboxVisible = not getgenv().HitboxVisible
        updateVisibility()
        updateCBtn()
    elseif input.KeyCode == Enum.KeyCode.Z then
        getgenv().WallCheckEnabled = not getgenv().WallCheckEnabled
    elseif input.KeyCode == Enum.KeyCode.J then
        whitelistGui.Visible = not whitelistGui.Visible
    elseif input.KeyCode == Enum.KeyCode.K then
        autoLockGui.Visible = not autoLockGui.Visible
    end
end)

-- =============================================
-- PLAYER SETUP + LIST AUTO-UPDATE
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
    lastVelocityCache[userId] = nil
    getgenv().Whitelist[userId] = nil
    getgenv().AutoLockPool[userId] = nil
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
notify("Demigod 🌟", "Mode: " .. getgenv().ScriptMode .. " | Q: Lock | C: Visibility | Z: Wall | J: Whitelist | K: Auto-Lock", 6)
print("Demigod script loaded — Mode: " .. getgenv().ScriptMode)
