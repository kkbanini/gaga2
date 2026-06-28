--[[
    Grow a Garden 2 — Auto GUI
    -----------------------------------------------------------------
    Features:
      1. Auto Plant     - loop-plants your selected/owned seed into empty plot tiles
      2. Auto Harvest   - loops Net.Garden.CollectFruit on ready fruit in your plot
      3. Auto Sell      - sells everything in your inventory on a loop (NPCS.SellAll)
      4. Anti-AFK       - hooks LocalPlayer.Idled; jumps (Space keypress) to avoid idle kicks
      5. Auto Buy Seed  - buys selected seeds (multi-select checkboxes, fixed order)
      6. Auto Buy Gear  - buys selected gear  (multi-select checkboxes, fixed order)

    All actions use the game's OWN networking layer (ReplicatedStorage.SharedModules.Networking),
    which wraps the buffer-based Packet system. Verified remote signatures:
      Net.Plant.PlantSeed      : (Vector3 position, string seedName, Instance plot)
      Net.SeedShop.PurchaseSeed: (string seedName)
      Net.GearShop.PurchaseGear: (string gearName)
      Net.NPCS.SellAll         : ()
      Net.Garden.CollectFruit  : (string, string)   -- harvest (arg semantics best-effort)

    UI is a self-contained CoreGui ScreenGui (draggable, no external deps).
--]]

----------------------------------------------------------------------
-- Services / safe parent
----------------------------------------------------------------------
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local Workspace          = game:GetService("Workspace")
local VirtualUser        = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

-- Surface any fatal error visibly (executor prints don't reach the dev console).
local function __surfaceError(err)
    warn("[GAG2 Auto] FATAL:", err)
    pcall(function()
        -- PlayerGui first so the error is visible on mobile executors too (they block CoreGui).
        local cg = LocalPlayer:FindFirstChild("PlayerGui")
            or (pcall(function() return gethui() end) and gethui())
            or game:GetService("CoreGui")
        local prev = cg:FindFirstChild("GAG2_AutoGUI_ERRVAL"); if prev then prev:Destroy() end
        local sv = Instance.new("StringValue"); sv.Name = "GAG2_AutoGUI_ERRVAL"; sv.Value = tostring(err); sv.Parent = cg
        local prevG = cg:FindFirstChild("GAG2_AutoGUI_ERR"); if prevG then prevG:Destroy() end
        local sg = Instance.new("ScreenGui"); sg.Name = "GAG2_AutoGUI_ERR"; sg.ResetOnSpawn = false
        sg.DisplayOrder = 99999; sg.IgnoreGuiInset = true
        local f = Instance.new("Frame"); f.Size = UDim2.new(0,420,0,140); f.Position = UDim2.new(0,40,0,300)
        f.BackgroundColor3 = Color3.fromRGB(45,22,22); f.Parent = sg
        local t = Instance.new("TextLabel"); t.Size = UDim2.new(1,-12,1,-12); t.Position = UDim2.new(0,6,0,6)
        t.BackgroundTransparency = 1; t.TextWrapped = true; t.Font = Enum.Font.GothamMedium; t.TextSize = 13
        t.TextColor3 = Color3.fromRGB(255,175,175); t.TextXAlignment = Enum.TextXAlignment.Left
        t.TextYAlignment = Enum.TextYAlignment.Top; t.Text = "GAG2 Auto error:\n"..tostring(err); t.Parent = f
        sg.Parent = cg
    end)
end

local __ok, __err = pcall(function()

local function guiParent()
    -- PlayerGui renders on EVERY platform (PC + mobile executors). Mobile executors
    -- (Delta/Codex/etc.) sandbox CoreGui — parenting there silently fails, so the GUI
    -- never appears. PlayerGui is the universal, always-rendering container.
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, hui = pcall(function() return gethui() end)
    if ok and typeof(hui) == "Instance" then return hui end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LocalPlayer:WaitForChild("PlayerGui")
end

----------------------------------------------------------------------
-- Hardcoded, strictly-ordered shop lists (DO NOT sort — order is intentional)
----------------------------------------------------------------------
local SEED_LIST = {
    "Carrot Seed", "Blueberry Seed", "Strawberry Seed", "Apple Seed", "Tomato Seed",
    "Tulip Seed", "Baby Cactus Seed", "Bamboo Seed", "Cactus Seed", "Corn Seed",
    "Horned Melon Seed", "Pineapple Seed", "Banana Seed", "Coconut Seed", "Glow Mushroom Seed",
    "Grape Seed", "Green Bean Seed", "Mango Seed", "Mushroom Seed", "Acorn Seed",
    "Cherry Seed", "Dragon Fruit Seed", "Poison Ivy Seed", "Sunflower Seed", "Ghost Pepper Seed",
    "Poison Apple Seed", "Pomegranate Seed", "Venom Spitter Seed", "Venus Fly Trap Seed",
    "Dragon's Breath Seed", "Moon Bloom Seed",
}

local GEAR_LIST = {
    "Common Sprinkler", "Common Watering Can", "Sign", "Uncommon Sprinkler", "Rare Sprinkler",
    "Trowel", "Jump Mushroom", "Speed Mushroom", "Lantern", "Megaphone",
    "Shrink Mushroom", "Supersize Mushroom", "Gnome", "Flashbang", "Basic Pot",
    "Legendary Sprinkler", "Teleporter", "Invisibility Mushroom", "Wheelbarrow", "Player Magnet",
    "Strawberry Sniper", "Grappling Hook",
}

----------------------------------------------------------------------
-- Networking handle (the clean remote wrapper over Packet)
----------------------------------------------------------------------
local Net
do
    local ok, mod = pcall(function()
        return require(ReplicatedStorage.SharedModules.Networking)
    end)
    if not ok or type(mod) ~= "table" then
        warn("[GAG2 Auto] Could not require Networking module:", mod)
        return
    end
    Net = mod
end

-- Safe fire: Net.<Category>.<Action>:Fire(...)
local function fire(category, action, ...)
    local cat = Net[category]
    if not cat then return false, "no category "..tostring(category) end
    local remote = cat[action]
    if not remote or type(remote.Fire) ~= "function" then
        return false, "no action "..tostring(category).."."..tostring(action)
    end
    return pcall(function(...) remote:Fire(...) end, ...)
end

----------------------------------------------------------------------
-- Runtime discovery helpers (plot / tiles / inventory for plant + harvest)
----------------------------------------------------------------------
-- Strip the " Seed" suffix the shop uses → the base crop name the planter uses
-- (verified: shop "Carrot Seed", planter "Carrot").
local function baseSeedName(n) return (n:gsub("%s*Seed$", "")) end

local SEED_BASE = {}
for _, s in ipairs(SEED_LIST) do SEED_BASE[baseSeedName(s)] = true end

-- Your garden plot: the Model under Workspace.Gardens whose OwnerUserId is you.
-- (verified: Workspace.Gardens.PlotN with attrs Owner / OwnerUserId)
local function findMyPlot()
    local gardens = Workspace:FindFirstChild("Gardens")
    if not gardens then return nil end
    local uid, name = LocalPlayer.UserId, LocalPlayer.Name
    for _, p in ipairs(gardens:GetChildren()) do
        if p:GetAttribute("OwnerUserId") == uid or p:GetAttribute("Owner") == name then
            return p
        end
    end
    return nil
end

-- Seed Tools the player owns (named after a crop), from Character + Backpack.
local function getSeedTools()
    local tools = {}
    local function scan(cont)
        if not cont then return end
        for _, t in ipairs(cont:GetChildren()) do
            if t:IsA("Tool") and (SEED_BASE[baseSeedName(t.Name)] or t.Name:find("Seed")) then
                tools[#tools+1] = t
            end
        end
    end
    scan(LocalPlayer.Character)
    scan(LocalPlayer:FindFirstChild("Backpack"))
    return tools
end

-- Empty plant positions: raycast a grid onto the plot's soil beds (under Visual),
-- skipping spots already occupied by existing plants.
-- (verified: PlotSizeReference defines footprint; beds live in Visual; plant Y ≈ bed top)
local function getPlantPositions(plot, maxCount)
    local ref = plot:FindFirstChild("PlotSizeReference")
    local visual = plot:FindFirstChild("Visual")
    if not ref or not visual then return {} end
    -- occupied positions from existing plants (Plants/<UserId_PlantId>/Base)
    local occupied = {}
    local plants = plot:FindFirstChild("Plants")
    if plants then
        for _, pl in ipairs(plants:GetChildren()) do
            local base = pl:FindFirstChild("Base")
            local pos = base and base.Position or (pl:IsA("Model") and select(1, pl:GetBoundingBox()).Position)
            if pos then occupied[#occupied+1] = pos end
        end
    end
    local function isOccupied(p)
        for _, o in ipairs(occupied) do
            if math.abs(o.X-p.X) < 3 and math.abs(o.Z-p.Z) < 3 then return true end
        end
        return false
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { visual }
    local c, sx, sz = ref.Position, ref.Size.X, ref.Size.Z
    local minX, maxX = c.X - sx/2 + 2, c.X + sx/2 - 2
    local minZ, maxZ = c.Z - sz/2 + 2, c.Z + sz/2 - 2
    local out, step = {}, 4
    for x = minX, maxX, step do
        for z = minZ, maxZ, step do
            local hit = Workspace:Raycast(Vector3.new(x, c.Y + 25, z), Vector3.new(0, -60, 0), params)
            if hit then
                local p = hit.Position + Vector3.new(0, 0.1, 0)
                if not isOccupied(p) then
                    out[#out+1] = p
                    if maxCount and #out >= maxCount then return out end
                end
            end
        end
    end
    return out
end

-- Harvest jobs for ALL ready crops. Returns { plantId = ..., fruitId = ... }.
-- Two crop types (both verified live, plant/fruit count drops on success):
--   * Fruit-bearing (has a Fruits folder): CollectFruit(PlantId, FruitId) per ripe fruit.
--   * Single-harvest (no Fruits folder, e.g. Carrot/Bamboo): CollectFruit(PlantId, "")
--     when PlantGrowthReady — empty second arg, removes the whole plant.
local function getHarvestJobs(plot)
    local plants = plot:FindFirstChild("Plants")
    if not plants then return {} end
    local out = {}
    for _, plant in ipairs(plants:GetChildren()) do
        local pid = plant:GetAttribute("PlantId")
        if pid then
            local fruits = plant:FindFirstChild("Fruits")
            if fruits then
                -- fruit-bearing: collect each ripe fruit
                for _, fruit in ipairs(fruits:GetChildren()) do
                    local fid = fruit:GetAttribute("FruitId")
                    if fid then
                        local age, maxAge = fruit:GetAttribute("Age"), fruit:GetAttribute("MaxAge")
                        if (not age or not maxAge) or age >= maxAge then
                            out[#out+1] = { plantId = pid, fruitId = fid }
                        end
                    end
                end
            elseif plant:GetAttribute("PlantGrowthReady") then
                -- single-harvest crop: collect whole plant (empty fruitId)
                out[#out+1] = { plantId = pid, fruitId = "" }
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local State = {
    AutoPlant   = false,
    AutoHarvest = false,
    AutoSell    = false,
    AntiAFK     = false,
    BlackScreen = false,
    AutoBuySeed = false,
    AutoBuyGear = false,
    SelectedSeeds = {},  -- [name]=true
    SelectedGear  = {},  -- [name]=true
    Interval = 0.6,      -- seconds between loop ticks
}

local statusFn = function(_) end  -- set after UI built

-- Generation guard: each run bumps this token. Loops/connections from a previous
-- run see the mismatch and exit, so reloading never leaves zombie loops firing.
_G.GAG2_RUN = (_G.GAG2_RUN or 0) + 1
local MY_RUN = _G.GAG2_RUN

local function loopWorker(name, enabledKey, body)
    task.spawn(function()
        while _G.GAG2_RUN == MY_RUN do
            if State[enabledKey] then
                local ok, err = pcall(body)
                if not ok then statusFn(("[%s] error: %s"):format(name, tostring(err))) end
            end
            task.wait(State.Interval)
        end
    end)
end

----------------------------------------------------------------------
-- Anti-AFK (event-driven, never blocks the loops)
-- On idle, send a real Space keypress: the character JUMPS and the input resets
-- Roblox's idle timer (a raw Humanoid.Jump wouldn't count as input).
----------------------------------------------------------------------
local VirtualInputManager = game:GetService("VirtualInputManager")
pcall(function()
    LocalPlayer.Idled:Connect(function()
        if _G.GAG2_RUN ~= MY_RUN then return end  -- stale connection from an old run
        if not State.AntiAFK then return end
        local ok = pcall(function()
            VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Space, false, game)
            task.wait(0.12)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
        end)
        if ok then statusFn("[AntiAFK] jumped to reset idle timer") end
    end)
end)

----------------------------------------------------------------------
-- Black Screen (covers the screen + halts 3D rendering to save FPS while AFK farming)
-- Lives in its own top-level ScreenGui so it covers the main window too; toggle from the
-- GUI OR press RightShift (backup off-switch, since the cover hides the window).
----------------------------------------------------------------------
local RunService_BS = game:GetService("RunService")
do
    local old = guiParent():FindFirstChild("GAG2_BlackCover"); if old then old:Destroy() end
    local bg = Instance.new("ScreenGui")
    bg.Name = "GAG2_BlackCover"; bg.ResetOnSpawn = false; bg.IgnoreGuiInset = true
    bg.DisplayOrder = 100000   -- above the main window (9999); NOT 2e9 (that glitches rendering)
    bg.Enabled = false; bg.Parent = guiParent()
    local cover = Instance.new("Frame")
    cover.Size = UDim2.fromScale(1, 1); cover.BackgroundColor3 = Color3.new(0, 0, 0)
    cover.BorderSizePixel = 0; cover.Active = true; cover.ZIndex = 1; cover.Parent = bg

    -- Touch-accessible off-button (works without a keyboard, e.g. on an emulator/mobile).
    -- Lives above the cover so it's the only thing visible/tappable while black.
    local showBtn = Instance.new("TextButton")
    showBtn.Size = UDim2.fromOffset(170, 38); showBtn.Position = UDim2.new(0.5, -85, 0, 24)
    showBtn.BackgroundColor3 = Color3.fromRGB(255, 70, 105); showBtn.TextColor3 = Color3.new(1,1,1)
    showBtn.Font = Enum.Font.GothamBold; showBtn.TextSize = 14; showBtn.Text = "👁 Show Game"
    showBtn.ZIndex = 5; showBtn.Parent = bg
    local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(0, 10); sc.Parent = showBtn
    showBtn.MouseButton1Click:Connect(function() State.BlackScreen = false end)
    showBtn.TouchTap:Connect(function() State.BlackScreen = false end)

    local function apply(on)
        bg.Enabled = on
        pcall(function() RunService_BS:Set3dRenderingEnabled(not on) end)
    end
    -- apply only on change
    task.spawn(function()
        local last
        while _G.GAG2_RUN == MY_RUN do
            if State.BlackScreen ~= last then last = State.BlackScreen; apply(State.BlackScreen) end
            task.wait(0.2)
        end
    end)
    -- safety: if a newer run supersedes this one, make sure rendering is restored
    task.spawn(function()
        while _G.GAG2_RUN == MY_RUN do task.wait(1) end
        pcall(function() RunService_BS:Set3dRenderingEnabled(true) end)
    end)
end

----------------------------------------------------------------------
-- Automation loops
----------------------------------------------------------------------
-- Auto Sell
loopWorker("AutoSell", "AutoSell", function()
    fire("NPCS", "SellAll")
end)

-- Auto Buy Seed — PurchaseSeed wants the BASE name ("Carrot"), not "Carrot Seed" (verified).
loopWorker("AutoBuySeed", "AutoBuySeed", function()
    for _, seedName in ipairs(SEED_LIST) do
        if State.SelectedSeeds[seedName] then
            fire("SeedShop", "PurchaseSeed", baseSeedName(seedName))
            task.wait(0.08)
        end
    end
end)

-- Auto Buy Gear
loopWorker("AutoBuyGear", "AutoBuyGear", function()
    for _, gearName in ipairs(GEAR_LIST) do
        if State.SelectedGear[gearName] then
            fire("GearShop", "PurchaseGear", gearName)
            task.wait(0.08)
        end
    end
end)

-- Auto Plant  — PlantSeed(bedPosition, baseSeedName, equippedTool)
loopWorker("AutoPlant", "AutoPlant", function()
    local plot = findMyPlot()
    if not plot then statusFn("[AutoPlant] plot not found") return end
    local tools = getSeedTools()
    if #tools == 0 then statusFn("[AutoPlant] no seed tools in inventory") return end
    local spots = getPlantPositions(plot, #tools)
    if #spots == 0 then statusFn("[AutoPlant] no empty soil spots") return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    local planted = 0
    for i, tool in ipairs(tools) do
        if not State.AutoPlant then break end
        local pos = spots[i]; if not pos then break end
        -- equip so the tool sits in the character (matches the captured call shape)
        if hum and tool.Parent ~= LocalPlayer.Character then
            pcall(function() hum:EquipTool(tool) end)
        end
        local okFire = fire("Plant", "PlantSeed", pos, baseSeedName(tool.Name), tool)
        if okFire then planted += 1 end
        task.wait(0.15)
    end
    statusFn(("[AutoPlant] planted %d seed(s)"):format(planted))
end)

-- Auto Harvest  — CollectFruit(FruitId, fruitModelName)
loopWorker("AutoHarvest", "AutoHarvest", function()
    local plot = findMyPlot()
    if not plot then statusFn("[AutoHarvest] plot not found") return end
    local fruits = getHarvestJobs(plot)
    if #fruits == 0 then statusFn("[AutoHarvest] nothing ready to harvest") return end
    local n = 0
    for _, f in ipairs(fruits) do
        if not State.AutoHarvest then break end
        fire("Garden", "CollectFruit", f.plantId, f.fruitId)
        n += 1
        task.wait(0.05)
    end
    statusFn(("[AutoHarvest] collected %d fruit"):format(n))
end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local Instance_new = Instance.new
local COLORS = {
    bg     = Color3.fromRGB(24, 26, 32),
    panel  = Color3.fromRGB(32, 35, 43),
    accent = Color3.fromRGB(86, 196, 120),
    accent2= Color3.fromRGB(60, 130, 200),
    text   = Color3.fromRGB(235, 238, 242),
    sub    = Color3.fromRGB(150, 156, 168),
    off    = Color3.fromRGB(70, 74, 84),
}

local function corner(p, r)
    local c = Instance_new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = p; return c
end
local function pad(p, n)
    local u = Instance_new("UIPadding")
    u.PaddingTop = UDim.new(0,n); u.PaddingBottom = UDim.new(0,n)
    u.PaddingLeft = UDim.new(0,n); u.PaddingRight = UDim.new(0,n)
    u.Parent = p; return u
end

local old = guiParent():FindFirstChild("GAG2_AutoGUI")
if old then old:Destroy() end

local screen = Instance_new("ScreenGui")
screen.Name = "GAG2_AutoGUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 9999  -- render above other ScreenGuis (incl. the Cobalt spy overlay)
screen.IgnoreGuiInset = true
screen.Parent = guiParent()

local main = Instance_new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 340, 0, 460)
main.Position = UDim2.new(0, 40, 0.5, -230)
main.BackgroundColor3 = COLORS.bg
main.BorderSizePixel = 0
main.Active = true
main.Parent = screen
corner(main, 10)

local stroke = Instance_new("UIStroke")
stroke.Color = COLORS.accent; stroke.Thickness = 1; stroke.Transparency = 0.5
stroke.Parent = main

local title = Instance_new("Frame")
title.Size = UDim2.new(1, 0, 0, 38)
title.BackgroundColor3 = COLORS.panel
title.BorderSizePixel = 0
title.Parent = main
corner(title, 10)

local titleLabel = Instance_new("TextLabel")
titleLabel.BackgroundTransparency = 1
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.new(0, 12, 0, 0)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 15
titleLabel.TextColor3 = COLORS.text
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "🌱 Grow a Garden 2 — Auto"
titleLabel.Parent = title

local minBtn = Instance_new("TextButton")
minBtn.Size = UDim2.new(0, 28, 0, 28)
minBtn.Position = UDim2.new(1, -34, 0, 5)
minBtn.BackgroundColor3 = COLORS.off
minBtn.Text = "—"
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 16
minBtn.TextColor3 = COLORS.text
minBtn.Parent = title
corner(minBtn, 6)

local body = Instance_new("ScrollingFrame")
body.Size = UDim2.new(1, 0, 1, -38)
body.Position = UDim2.new(0, 0, 0, 38)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = COLORS.accent
body.CanvasSize = UDim2.new(0,0,0,0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = main
pad(body, 10)

local list = Instance_new("UIListLayout")
list.Padding = UDim.new(0, 8)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = body

local status = Instance_new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 18)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextColor3 = COLORS.sub
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Text = "ready."
status.LayoutOrder = 999
status.Parent = body
statusFn = function(msg) status.Text = tostring(msg) end

local order = 0
local function nextOrder() order += 1; return order end

local function sectionHeader(text)
    local h = Instance_new("TextLabel")
    h.Size = UDim2.new(1, 0, 0, 16)
    h.BackgroundTransparency = 1
    h.Font = Enum.Font.GothamBold
    h.TextSize = 11
    h.TextColor3 = COLORS.accent
    h.TextXAlignment = Enum.TextXAlignment.Left
    h.Text = text:upper()
    h.LayoutOrder = nextOrder()
    h.Parent = body
    return h
end

local function makeToggle(text, stateKey)
    local row = Instance_new("Frame")
    row.Size = UDim2.new(1, 0, 0, 34)
    row.BackgroundColor3 = COLORS.panel
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 6)

    local lbl = Instance_new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -64, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextColor3 = COLORS.text
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = text
    lbl.Parent = row

    local btn = Instance_new("TextButton")
    btn.Size = UDim2.new(0, 46, 0, 22)
    btn.Position = UDim2.new(1, -56, 0.5, -11)
    btn.BackgroundColor3 = COLORS.off
    btn.Text = "OFF"
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = COLORS.text
    btn.AutoButtonColor = false
    btn.Parent = row
    corner(btn, 11)

    btn.MouseButton1Click:Connect(function()
        State[stateKey] = not State[stateKey]
        local on = State[stateKey]
        btn.BackgroundColor3 = on and COLORS.accent or COLORS.off
        btn.Text = on and "ON" or "OFF"
        statusFn(text .. (on and " enabled" or " disabled"))
    end)
    return row
end

-- Multi-select checkbox list. `names` order is preserved exactly (no sorting).
local function makeChecklist(title_text, names, selectedTbl)
    local header = Instance_new("TextLabel")
    header.Size = UDim2.new(1, 0, 0, 18)
    header.BackgroundTransparency = 1
    header.Font = Enum.Font.GothamSemibold
    header.TextSize = 12
    header.TextColor3 = COLORS.sub
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Text = title_text .. ("  (%d)"):format(#names)
    header.LayoutOrder = nextOrder()
    header.Parent = body

    -- Select-all / clear row
    local tools = Instance_new("Frame")
    tools.Size = UDim2.new(1, 0, 0, 22)
    tools.BackgroundTransparency = 1
    tools.LayoutOrder = nextOrder()
    tools.Parent = body
    local tl = Instance_new("UIListLayout")
    tl.FillDirection = Enum.FillDirection.Horizontal
    tl.Padding = UDim.new(0, 6)
    tl.Parent = tools

    local tickRefs = {}
    local function smallBtn(txt, cb)
        local b = Instance_new("TextButton")
        b.Size = UDim2.new(0, 70, 1, 0)
        b.BackgroundColor3 = COLORS.panel
        b.Text = txt
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 11
        b.TextColor3 = COLORS.text
        b.AutoButtonColor = true
        b.Parent = tools
        corner(b, 5)
        b.MouseButton1Click:Connect(cb)
    end

    local box = Instance_new("ScrollingFrame")
    box.Size = UDim2.new(1, 0, 0, math.min(150, math.max(28, #names * 26 + 4)))
    box.BackgroundColor3 = COLORS.panel
    box.BorderSizePixel = 0
    box.ScrollBarThickness = 4
    box.ScrollBarImageColor3 = COLORS.accent2
    box.CanvasSize = UDim2.new(0,0,0,0)
    box.AutomaticCanvasSize = Enum.AutomaticSize.Y
    box.LayoutOrder = nextOrder()
    box.Parent = body
    corner(box, 6)
    pad(box, 4)

    local bl = Instance_new("UIListLayout")
    bl.Padding = UDim.new(0, 2)
    bl.SortOrder = Enum.SortOrder.LayoutOrder
    bl.Parent = box

    for i, nm in ipairs(names) do
        local item = Instance_new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 24)
        item.BackgroundColor3 = COLORS.bg
        item.AutoButtonColor = false
        item.Text = ""
        item.LayoutOrder = i
        item.Parent = box
        corner(item, 4)

        local tick = Instance_new("Frame")
        tick.Size = UDim2.new(0, 16, 0, 16)
        tick.Position = UDim2.new(0, 6, 0.5, -8)
        tick.BackgroundColor3 = selectedTbl[nm] and COLORS.accent or COLORS.off
        tick.BorderSizePixel = 0
        tick.Parent = item
        corner(tick, 4)
        tickRefs[nm] = tick

        local idx = Instance_new("TextLabel")
        idx.BackgroundTransparency = 1
        idx.Size = UDim2.new(0, 22, 1, 0)
        idx.Position = UDim2.new(0, 26, 0, 0)
        idx.Font = Enum.Font.Gotham
        idx.TextSize = 10
        idx.TextColor3 = COLORS.sub
        idx.TextXAlignment = Enum.TextXAlignment.Left
        idx.Text = tostring(i)
        idx.Parent = item

        local nameLbl = Instance_new("TextLabel")
        nameLbl.BackgroundTransparency = 1
        nameLbl.Size = UDim2.new(1, -52, 1, 0)
        nameLbl.Position = UDim2.new(0, 48, 0, 0)
        nameLbl.Font = Enum.Font.Gotham
        nameLbl.TextSize = 12
        nameLbl.TextColor3 = COLORS.text
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Text = nm
        nameLbl.Parent = item

        item.MouseButton1Click:Connect(function()
            selectedTbl[nm] = not selectedTbl[nm] or nil
            tick.BackgroundColor3 = selectedTbl[nm] and COLORS.accent or COLORS.off
        end)
    end

    smallBtn("Select All", function()
        for _, nm in ipairs(names) do
            selectedTbl[nm] = true
            if tickRefs[nm] then tickRefs[nm].BackgroundColor3 = COLORS.accent end
        end
        statusFn(title_text .. ": all selected")
    end)
    smallBtn("Clear", function()
        for _, nm in ipairs(names) do
            selectedTbl[nm] = nil
            if tickRefs[nm] then tickRefs[nm].BackgroundColor3 = COLORS.off end
        end
        statusFn(title_text .. ": cleared")
    end)
end

----------------------------------------------------------------------
-- Build UI content
----------------------------------------------------------------------
sectionHeader("Automation")
makeToggle("Auto Plant", "AutoPlant")
makeToggle("Auto Harvest", "AutoHarvest")
makeToggle("Auto Sell (sell all)", "AutoSell")
makeToggle("Anti-AFK", "AntiAFK")
makeToggle("Black Screen (RightShift)", "BlackScreen")

sectionHeader("Auto Buy Seed")
makeToggle("Auto Buy Seed", "AutoBuySeed")
makeChecklist("Seeds to buy", SEED_LIST, State.SelectedSeeds)

sectionHeader("Auto Buy Gear")
makeToggle("Auto Buy Gear", "AutoBuyGear")
makeChecklist("Gear to buy", GEAR_LIST, State.SelectedGear)

----------------------------------------------------------------------
-- Dragging + minimize
----------------------------------------------------------------------
do
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                      startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        main.Size = minimized and UDim2.new(0, 340, 0, 38) or UDim2.new(0, 340, 0, 460)
        minBtn.Text = minimized and "+" or "—"
    end)

    -- RightShift: toggle Black Screen (backup off-switch when the cover hides the window)
    UserInputService.InputBegan:Connect(function(input, gpe)
        if _G.GAG2_RUN ~= MY_RUN then return end   -- ignore stale connections from old reloads
        if input.KeyCode == Enum.KeyCode.RightShift then
            State.BlackScreen = not State.BlackScreen
        end
    end)
end

statusFn("GAG2 Auto loaded — toggle features above.")
print("[GAG2 Auto] GUI loaded. Net categories:",
    Net.Plant ~= nil, Net.Garden ~= nil, Net.SeedShop ~= nil, Net.GearShop ~= nil, Net.NPCS ~= nil)

end) -- end protected main
if not __ok then __surfaceError(__err) end
