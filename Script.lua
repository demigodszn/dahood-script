-- =============================================
-- HITBOX + STREAMABLE CAMLOCK + PING PREDICTION
-- =============================================
getgenv().HitboxSize = Vector3.new(8, 8, 8)
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().CamlockTarget = nil
getgenv().WallCheckEnabled = false

-- Less smooth = more precise/snappy
local SMOOTHNESS = 0.12
local AIM_OFFSET = Vector3.new(0, 1.6, 0)
local PING_MIN = 0.059
local PING_MAX = 0.080

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local connections = {}
local healthConnections = {}
local lastVelocityCache = {}
local camlockBound = false
local carriedCharacter = nil
local wasCarrying = false
local currentLookDir = nil

-- =============================================
-- NOTIFICATION
-- =============================================

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 3
        })
    end)
end

-- =============================================
-- GUI — Q BUTTON ONLY
-- =============================================

local existingGui = LocalPlayer.PlayerGui:FindFirstChild("DemigodGui")
if existingGui then existingGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DemigodGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = LocalPlayer.PlayerGui

local qFrame = Instance.new("Frame")
qFrame.Size = UDim2.new(0, 50, 0, 50)
qFrame.Position = UDim2.new(0.5, -25, 1, -120)
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

-- =============================================
-- HITBOX FUNCTIONS
-- =============================================

local function disableAllCollision(character)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
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
        for _, conn in ipairs(connections[userId]) do
            conn:Disconnect()
        end
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
    if humanoid and humanoid.Health <= 0 then return end

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
        if targetPart.Size ~= getgenv().HitboxSize then
            targetPart.Size = getgenv().HitboxSize
        end
    end))

    table.insert(connections[userId], targetPart:GetPropertyChangedSignal("CanCollide"):Connect(function()
        if targetPart.CanCollide ~= false then
            targetPart.CanCollide = false
        end
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
        if humanoid.Health <= 0 then
            removeHitbox(player)
        end
    end)
end

local function updateVisibility()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then
                local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
                if targetPart and targetPart:IsA("BasePart") then
                    targetPart.Transparency = getgenv().HitboxVisible and 0.5 or 1
                end
            end
        end
    end
    notify("Hitbox", "Visibility: " .. (getgenv().HitboxVisible and "Visible" or "Invisible"), 2)
end

-- =============================================
-- CAMLOCK FUNCTIONS
-- =============================================

local function isKnockedOrDead(player)
    if not player or not player.Character then return true end
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return true end
    return humanoid.Health <= 0
end

local function hasLineOfSight(targetHRP)
    if not getgenv().WallCheckEnabled then return true end
    local localChar = LocalPlayer.Character
    if not localChar then return false end

    local origin = Camera.CFrame.Position
    local direction = targetHRP.Position - origin
    local distance = direction.Magnitude

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = {localChar, targetHRP.Parent}

    local result = workspace:Raycast(origin, direction.Unit * distance, raycastParams)
    return result == nil
end

local function getAcceleration(player, currentVelocity)
    local userId = player.UserId
    local now = tick()

    if not lastVelocityCache[userId] then
        lastVelocityCache[userId] = {velocity = currentVelocity, time = now}
        return Vector3.new(0, 0, 0)
    end

    local cached = lastVelocityCache[userId]
    local dt = now - cached.time
    if dt <= 0 then return Vector3.new(0, 0, 0) end

    local acceleration = (currentVelocity - cached.velocity) / dt
    lastVelocityCache[userId] = {velocity = currentVelocity, time = now}
    return acceleration
end

local function getPredictedPosition(targetHRP, player)
    local ping = math.clamp(LocalPlayer:GetNetworkPing(), PING_MIN, PING_MAX)
    local velocity = targetHRP.AssemblyLinearVelocity
    local acceleration = getAcceleration(player, velocity)

    local clampedAccel = Vector3.new(
        math.clamp(acceleration.X, -80, 80),
        math.clamp(acceleration.Y, -80, 80),
        math.clamp(acceleration.Z, -80, 80)
    )

    return targetHRP.Position
        + (velocity * ping)
        + (0.5 * clampedAccel * ping * ping)
        + AIM_OFFSET
end

local function getPlayerInCrosshair(exclude)
    local bestTarget = nil
    local bestDot = -math.huge
    local cameraLook = Camera.CFrame.LookVector

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player ~= exclude and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hrp and hrp:IsDescendantOf(workspace) and not isKnockedOrDead(player) then
                if not getgenv().WallCheckEnabled or hasLineOfSight(hrp) then
                    local dirToPlayer = (hrp.Position - Camera.CFrame.Position).Unit
                    local dot = cameraLook:Dot(dirToPlayer)
                    if dot > bestDot then
                        bestDot = dot
                        bestTarget = player
                    end
                end
            end
        end
    end
    return bestTarget
end

local function releaseTarget(reason)
    getgenv().CamlockTarget = nil
    currentLookDir = nil
    updateQBtn(false)
    if reason then
        notify("Camlock", reason, 2)
    end
end

local function handleQ()
    if getgenv().CamlockTarget then
        releaseTarget("Released")
    else
        local target = getPlayerInCrosshair(nil)
        if target then
            getgenv().CamlockTarget = target
            currentLookDir = nil
            updateQBtn(true)
            notify("Camlock", "Locked", 2)
        else
            notify("Camlock", "No target in view", 2)
        end
    end
end

qBtn.MouseButton1Click:Connect(function()
    handleQ()
end)

-- =============================================
-- CAMLOCK LOOP
-- KEY FIX: BindToRenderStep at Camera priority + 1
-- This runs AFTER Roblox updates the camera position
-- for character movement — so Roblox moves the camera
-- to follow your character first, THEN we rotate it
-- toward the target. Character never leaves screen.
-- Camera never freezes on fast movement.
-- =============================================

Camera.CameraType = Enum.CameraType.Custom

RunService:BindToRenderStep("DemigodCamlock", Enum.RenderPriority.Camera.Value + 1, function(dt)
    if not getgenv().CamlockTarget then return end

    local target = getgenv().CamlockTarget

    -- Hard dead check
    if not target.Character then
        releaseTarget("Released — Target lost")
        return
    end

    local humanoid = target.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        releaseTarget("Released — Target down")
        return
    end

    local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
    if not targetHRP or not targetHRP:IsDescendantOf(workspace) then
        releaseTarget("Released — Target lost")
        return
    end

    if getgenv().WallCheckEnabled and not hasLineOfSight(targetHRP) then return end

    -- Predicted position
    local predictedPos = getPredictedPosition(targetHRP, target)

    -- Read camera AFTER Roblox already moved it for character movement
    -- This is the crucial fix — position is already correct, we only change look
    local currentCF = Camera.CFrame
    local camPos = currentCF.Position

    -- Direction from current camera position to predicted target position
    local targetDir = (predictedPos - camPos)

    -- FORCEHIT: if target is very close to crosshair, snap harder
    local currentDir = currentCF.LookVector
    local dot = currentDir:Dot(targetDir.Unit)
    local forcehitAlpha = dot > 0.98 and 1 or SMOOTHNESS

    if not currentLookDir then
        currentLookDir = currentDir
    end

    local alpha = 1 - (1 - forcehitAlpha) ^ (dt * 60)
    currentLookDir = currentLookDir:Lerp(targetDir.Unit, alpha).Unit

    -- Only rotate, never touch position — Roblox owns the position
    Camera.CFrame = CFrame.new(camPos, camPos + currentLookDir)
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
        if weld:IsA("WeldConstraint") or weld:IsA("Weld") or weld:IsA("Motor6D") then
            local otherPart = weld:IsA("WeldConstraint") and weld.Part1 or weld.Part1
            if otherPart and otherPart.Parent ~= character then
                return otherPart.Parent
            end
        end
    end

    for _, weld in ipairs(character:GetDescendants()) do
        if weld:IsA("WeldConstraint") or weld:IsA("Weld") then
            local otherPart = weld:IsA("WeldConstraint") and weld.Part1 or weld.Part1
            if otherPart and otherPart.Parent ~= character and otherPart.Parent:FindFirstChildOfClass("Humanoid") then
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
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health <= 0 then continue end

            local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
            if targetPart and targetPart:IsA("BasePart") then
                local sizeMatch = targetPart.Size.X == getgenv().HitboxSize.X
                    and targetPart.Size.Y == getgenv().HitboxSize.Y
                    and targetPart.Size.Z == getgenv().HitboxSize.Z
                if not sizeMatch or targetPart.CanCollide ~= false then
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
    if input.KeyCode == Enum.KeyCode.Q then
        handleQ()
    elseif input.KeyCode == Enum.KeyCode.C then
        getgenv().HitboxVisible = not getgenv().HitboxVisible
        updateVisibility()
    elseif input.KeyCode == Enum.KeyCode.Z then
        getgenv().WallCheckEnabled = not getgenv().WallCheckEnabled
        notify("Wall Check", getgenv().WallCheckEnabled and "ON" or "OFF", 2)
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
    end)
end

Players.PlayerAdded:Connect(function(player)
    setupPlayer(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end

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
notify("Demigod 🌟", "Loaded — Q: Lock | C: Visibility | Z: Wall Check", 5)
print("Demigod script loaded")
