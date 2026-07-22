-- =============================================
-- HITBOX + CAMLOCK + PING PREDICTION
-- =============================================
getgenv().HitboxSize = Vector3.new(8, 8, 8)
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().CamlockTarget = nil
getgenv().WallCheckEnabled = false

local SMOOTHNESS = 0.095
local AIM_OFFSET = Vector3.new(0, 1.6, 0)
local PING_MIN = 0.059
local PING_MAX = 0.080
local KNOCK_THRESHOLD = 2 -- was 0, Da Hood knock can settle at 1-2

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

local existingGui = LocalPlayer.PlayerGui:FindFirstChild("DemigodGui")
if existingGui then existingGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DemigodGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = LocalPlayer.PlayerGui

-- Q Button — bottom center area, shifted left of C
local qFrame = Instance.new("Frame")
qFrame.Size = UDim2.new(0, 50, 0, 50)
qFrame.Position = UDim2.new(0.5, -55, 1, -120)
qFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
qFrame.BackgroundTransparency = 0.3
qFrame.Active = true
qFrame.Parent = screenGui
Instance.new("UICorner", qFrame).CornerRadius = UDim.new(1, 0)

local qBtn = Instance.new("TextButton")
qBtn.Size = UDim2.new(1, 0, 1, 0)
qBtn.BackgroundTransparency = 1
qBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
qBtn.Text = "Q"
qBtn.Font = Enum.Font.GothamBold
qBtn.TextSize = 22
qBtn.Parent = qFrame

local qDot = Instance.new("Frame")
qDot.Size = UDim2.new(0, 10, 0, 10)
qDot.Position = UDim2.new(1, -2, 0, -2)
qDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
qDot.Parent = qFrame
Instance.new("UICorner", qDot).CornerRadius = UDim.new(1, 0)

local function updateQBtn(locked)
    if locked then
        qFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        qDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        qFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        qDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

-- C Button — bottom center area, right next to Q
local cFrame = Instance.new("Frame")
cFrame.Size = UDim2.new(0, 50, 0, 50)
cFrame.Position = UDim2.new(0.5, 5, 1, -120)
cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
cFrame.BackgroundTransparency = 0.3
cFrame.Active = true
cFrame.Parent = screenGui
Instance.new("UICorner", cFrame).CornerRadius = UDim.new(1, 0)

local cBtn = Instance.new("TextButton")
cBtn.Size = UDim2.new(1, 0, 1, 0)
cBtn.BackgroundTransparency = 1
cBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
cBtn.Text = "C"
cBtn.Font = Enum.Font.GothamBold
cBtn.TextSize = 22
cBtn.Parent = cFrame

local cDot = Instance.new("Frame")
cDot.Size = UDim2.new(0, 10, 0, 10)
cDot.Position = UDim2.new(1, -2, 0, -2)
cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
cDot.Parent = cFrame
Instance.new("UICorner", cDot).CornerRadius = UDim.new(1, 0)

local function updateCBtn()
    if getgenv().HitboxVisible then
        cFrame.BackgroundColor3 = Color3.fromRGB(10, 35, 10)
        cDot.BackgroundColor3 = Color3.fromRGB(80, 255, 100)
    else
        cFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        cDot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
    end
end

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
        if player ~= LocalPlayer and player.Character then
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

cBtn.MouseButton1Click:Connect(function()
    getgenv().HitboxVisible = not getgenv().HitboxVisible
    updateVisibility()
    updateCBtn()
end)

-- =============================================
-- CAMLOCK
-- FIX: knock threshold raised from 0 to 2 everywhere.
-- FIX: shake removed — no more binary snap-to-1 when
-- dot > 0.98. Replaced with a continuous alpha curve
-- that increases smoothly as you approach the target
-- instead of jumping, which was causing oscillation.
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

-- Only ever called from handleQ — never from inside the render loop.
-- This is what prevents a locked target from being silently swapped.
local function getPlayerInCrosshair()
    local best, bestDot = nil, -math.huge
    local look = Camera.CFrame.LookVector
    local camPos = Camera.CFrame.Position

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
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

local function releaseTarget()
    getgenv().CamlockTarget = nil
    updateQBtn(false)
end

local function handleQ()
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

qBtn.MouseButton1Click:Connect(handleQ)

Camera.CameraType = Enum.CameraType.Custom
pcall(function() RunService:UnbindFromRenderStep("DemigodCamlock") end)

RunService:BindToRenderStep("DemigodCamlock", Enum.RenderPriority.Camera.Value + 1, function(dt)
    local target = getgenv().CamlockTarget
    if not target then return end

    if target == LocalPlayer then
        releaseTarget()
        return
    end

    if not target.Character then releaseTarget(); return end

    local hum = target.Character:FindFirstChildOfClass("Humanoid")
    if not hum then releaseTarget(); return end

    local ok, health = pcall(function() return hum.Health end)
    if not ok or health <= KNOCK_THRESHOLD then releaseTarget(); return end

    local hrp = target.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not hrp:IsDescendantOf(workspace) then releaseTarget(); return end

    if getgenv().WallCheckEnabled and not hasLineOfSight(hrp) then return end

    -- Position always read fresh, after Roblox already moved the camera
    -- for character movement. Never cached, never touched by us.
    local camCF = Camera.CFrame
    local camPos = camCF.Position
    local currentLook = camCF.LookVector

    local predicted = getPredictedPosition(hrp, target)
    local toTarget = predicted - camPos
    if toTarget.Magnitude < 0.1 then return end

    local targetDir = toTarget.Unit
    local dot = currentLook:Dot(targetDir)

    -- SHAKE FIX: no more binary snap. Alpha now scales continuously
    -- with how close the dot already is — approaches 1 smoothly as
    -- you near-perfectly align, instead of jumping there and back.
    local closeness = math.clamp((dot - 0.9) / 0.1, 0, 1) -- 0 at dot=0.9, 1 at dot=1.0
    local baseAlpha = 1 - (1 - SMOOTHNESS) ^ (dt * 60)
    local alpha = baseAlpha + (1 - baseAlpha) * closeness * 0.6 -- capped boost, never a hard 1

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
        if player ~= LocalPlayer and player.Character then
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

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.Q then
        handleQ()
    elseif input.KeyCode == Enum.KeyCode.C then
        getgenv().HitboxVisible = not getgenv().HitboxVisible
        updateVisibility()
        updateCBtn()
    elseif input.KeyCode == Enum.KeyCode.Z then
        getgenv().WallCheckEnabled = not getgenv().WallCheckEnabled
    end
end)

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

Players.PlayerAdded:Connect(setupPlayer)
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
end)

task.spawn(function()
    while true do
        task.wait(5)
        validateHitboxes()
    end
end)

updateQBtn(false)
updateCBtn()
notify("Demigod 🌟", "Loaded — Q: Lock | C: Visibility | Z: Wall Check", 5)
print("Demigod script loaded")
