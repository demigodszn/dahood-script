-- =============================================
-- HITBOX + STREAMABLE CAMLOCK + PING PREDICTION
-- =============================================
getgenv().HitboxSize = Vector3.new(8, 8, 8)
getgenv().TargetPart = "HumanoidRootPart"
getgenv().Enabled = true
getgenv().HitboxVisible = true
getgenv().CamlockEnabled = false
getgenv().CamlockTarget = nil

local SMOOTHNESS = 0.095
local AIM_OFFSET = Vector3.new(0, 1.6, 0)
local PING_MIN = 0.059
local PING_MAX = 0.080

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local success, UIS = pcall(function() return game:GetService("UserInputService") end)

local connections = {}
local healthConnections = {}
local camlockConnection = nil
local carriedCharacter = nil
local wasCarrying = false

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

    print("Hitbox removed for stomping: " .. player.Name)
end

local function applyHitbox(player)
    if not getgenv().Enabled or player == LocalPlayer then return end
    if not player.Character then return end

    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= 0 then
        print("Skipping hitbox for dead player: " .. player.Name)
        return
    end

    local targetPart = player.Character:FindFirstChild(getgenv().TargetPart)
    if not targetPart or not targetPart:IsA("BasePart") then return end

    targetPart.Size = getgenv().HitboxSize
    targetPart.Transparency = getgenv().HitboxVisible and 0.5 or 1
    targetPart.CanCollide = false

    disableAllCollision(player.Character)

    local userId = player.UserId
    if connections[userId] then
        for _, conn in ipairs(connections[userId]) do
            conn:Disconnect()
        end
    end
    connections[userId] = {}

    table.insert(connections[userId], targetPart:GetPropertyChangedSignal("Size"):Connect(function()
        if targetPart.Size.X ~= getgenv().HitboxSize.X
            or targetPart.Size.Y ~= getgenv().HitboxSize.Y
            or targetPart.Size.Z ~= getgenv().HitboxSize.Z then
            targetPart.Size = getgenv().HitboxSize
        end
    end))

    table.insert(connections[userId], targetPart:GetPropertyChangedSignal("CanCollide"):Connect(function()
        if targetPart.CanCollide ~= false then
            targetPart.CanCollide = false
        end
    end))

    for _, part in ipairs(player.Character:GetDescendants()) do
        if part:IsA("BasePart") then
            table.insert(connections[userId], part:GetPropertyChangedSignal("CanCollide"):Connect(function()
                if part.CanCollide ~= false then
                    part.CanCollide = false
                end
            end))
        end
    end

    print("Hitbox locked for " .. player.Name)
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
            print(player.Name .. " knocked/dead — removing hitbox for stomp")
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

local function getNearestPlayer(exclude)
    local nearest = nil
    local nearestDist = math.huge
    local localChar = LocalPlayer.Character
    if not localChar then return nil end
    local localHRP = localChar:FindFirstChild("HumanoidRootPart")
    if not localHRP then return nil end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player ~= exclude and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hrp and hrp:IsDescendantOf(workspace) and not isKnockedOrDead(player) then
                local dist = (hrp.Position - localHRP.Position).Magnitude
                if dist < nearestDist then
                    nearestDist = dist
                    nearest = player
                end
            end
        end
    end
    return nearest
end

local function cycleTarget()
    if not getgenv().CamlockEnabled then return end
    local newTarget = getNearestPlayer(getgenv().CamlockTarget)
    if newTarget then
        getgenv().CamlockTarget = newTarget
        notify("Camlock", "Switched to: " .. newTarget.Name, 2)
        print("Switched target: " .. newTarget.Name)
    else
        notify("Camlock", "No other targets nearby", 2)
        print("No other alive targets nearby")
    end
end

local function startCamlock()
    if camlockConnection then camlockConnection:Disconnect() end
    Camera.CameraType = Enum.CameraType.Scriptable

    camlockConnection = RunService.RenderStepped:Connect(function(dt)
        if not getgenv().CamlockEnabled then return end

        local target = getgenv().CamlockTarget

        if not target or not target.Character or isKnockedOrDead(target) then
            target = getNearestPlayer(nil)
            getgenv().CamlockTarget = target
            if not target then return end
        end

        local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
        if not targetHRP or not targetHRP:IsDescendantOf(workspace) then
            getgenv().CamlockTarget = getNearestPlayer(nil)
            return
        end

        local ping = math.clamp(LocalPlayer:GetNetworkPing(), PING_MIN, PING_MAX)
        local velocity = targetHRP.AssemblyLinearVelocity
        local predictedPos = targetHRP.Position + (velocity * ping) + AIM_OFFSET

        local currentCF = Camera.CFrame
        local alpha = 1 - (1 - SMOOTHNESS) ^ (dt * 60)
        local targetCF = CFrame.new(currentCF.Position, predictedPos)
        Camera.CFrame = currentCF:Lerp(targetCF, alpha)
    end)
end

local function stopCamlock()
    if camlockConnection then
        camlockConnection:Disconnect()
        camlockConnection = nil
    end
    Camera.CameraType = Enum.CameraType.Custom
    getgenv().CamlockTarget = nil
end

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

if UIS then
    UIS.InputBegan:Connect(function(input, gameProcessed)
        if input.KeyCode == Enum.KeyCode.Q then
            getgenv().CamlockEnabled = not getgenv().CamlockEnabled
            if getgenv().CamlockEnabled then
                getgenv().CamlockTarget = getNearestPlayer(nil)
                startCamlock()
                local targetName = getgenv().CamlockTarget and getgenv().CamlockTarget.Name or "No target"
                notify("Camlock", "ON — " .. targetName, 3)
            else
                stopCamlock()
                notify("Camlock", "OFF", 3)
            end
        elseif input.KeyCode == Enum.KeyCode.C then
            if getgenv().CamlockEnabled then
                cycleTarget()
            else
                getgenv().HitboxVisible = not getgenv().HitboxVisible
                updateVisibility()
            end
        end
    end)
end

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
        print(player.Name .. " respawned — hitbox reapplied")
    end)
end

Players.PlayerAdded:Connect(function(player)
    print("Player joined: " .. player.Name)
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
end)

task.spawn(function()
    while true do
        task.wait(5)
        validateHitboxes()
    end
end)

notify("Script", "Loaded — Q: Camlock | C: Next Target / Hitbox Visibility", 5)
print("Script loaded — Hitbox: " .. tostring(getgenv().HitboxSize))
print("Q — toggle camlock | C — next target / toggle hitbox visibility")
