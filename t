local findfirstchild = findfirstchild
local getchildren = getchildren
local worldtoscreenpoint = worldtoscreenpoint
local getlocalplayer = getlocalplayer
local getposition = getposition
local getname = getname
local getclassname = getclassname
local findservice = findservice

local config = {
    player = {
            enabled = true,
        show_names = true,
        show_skeleton = true,
        text_size = 14,
        line_thickness = 1.5,
        name_y_offset = 35,
        color = {0, 255, 0} 
    },
    beast = {
            enabled = true,
        show_names = true,
        show_skeleton = true,
        text_size = 14,
        line_thickness = 1.5,
        name_y_offset = 35,
        color = {255, 0, 0} 
    },
    computer = {
        enabled = true,
        show_names = true,
        show_distance = false,
        text_size = 14,
        name_y_offset = 35,
        distance_y_offset = 15,
        color = {255, 215, 0} 
    },
    freezepod = {
        enabled = true,
        show_names = true,
        show_distance = false,
        text_size = 14,
        name_y_offset = 35,
        distance_y_offset = 15,
        color = {0, 150, 255} 
    }
}

local mapCache = {}
local computerCache = {}
local freezePodCache = {}
local lastUpdate = 0
local updateInterval = 0.5

local ignoreModels = {
    ["ProServersBoard"] = true,
    ["VCServersBoard"] = true,
    ["MapVotingBoard"] = true,
    ["MerchBoard"] = true,
    ["VipBoard"] = true
}

local MEM_OFFSET_X = 0x204
local MEM_OFFSET_Y = 0x208
local MEM_OFFSET_Z = 0x20c

local LINE_THICKNESS = 1.5
local PLAYER_COLOR = {0, 255, 0} 
local BEAST_COLOR = {255, 0, 0} 
local MAX_PLAYERS_TO_DRAW = 15
local DEBUG_TEXT_VISIBLE = false
local NAME_TEXT_SIZE = 18
local NAME_Y_OFFSET = 35 
local RENDER_STEP = 0.001 

local CONNECTIONS = {

    {"Head", "Torso"},
    {"Torso", "Left Leg"},
    {"Torso", "Right Leg"},

    {"Left Arm", "Torso"},
    {"Right Arm", "Torso"},
    {"Left Arm", "Left Arm"}, 
    {"Right Arm", "Right Arm"}, 

    {"Left Leg", "Left Leg"}, 
    {"Right Leg", "Right Leg"}, 

    {"Head", "Head"} 
}

local player_data_cache = {}
local line_pool = {}
local text_pool = {}
local MAX_LINES = #CONNECTIONS

local mathfloor = math.floor
local mathsqrt = math.sqrt
local drawingnew = Drawing.new

local workspace = findservice(Game, 'Workspace')
local players = findservice(Game, 'Players')
local camera = findfirstchild(workspace, 'Camera')
local localplayer = getlocalplayer()

local stop = false
local caches = {}

local getpos = getposition
local getchildren = getchildren
local findfirstchild = findfirstchild
local isdescendantof = isdescendantof
local worldtoscreen = worldtoscreenpoint
local tick = tick
local wait = wait

local player_cache = {}

local function update_player_cache()
    player_cache = {}
    for _, player in pairs(getchildren(players)) do
        player_cache[getname(player)] = true
    end
end

local function is_valid_player(name)
    return player_cache[name] or false
end

local function get_rootpart(model)
    return findfirstchild(model, "RootPart")
end

local function getmagnitude(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return mathsqrt(dx * dx + dy * dy + dz * dz)
end

local function draw(class, props)
    local obj = drawingnew(class)
    for i, prop in pairs(props) do
        obj[i] = prop
    end
    return obj
end

local function is_valid_part(part)
    if part then
        local class_name = getclassname(part)
        return class_name == "Part" or class_name == "MeshPart" or class_name == "UnionOperation"
    end
    return false
end

local function create_esp_elements(color, radius)
    return {
        text = draw('Text', {
            Text = '',
            Size = 18, 
            Font = config.font,
            Color = color,
            Center = true,
            Outline = true,
            Visible = false,
            Transparency = 1
        }),
        circle = draw('Circle', {
            Radius = radius,
            Thickness = 1,
            NumSides = 12,
            Filled = true,
            Color = color,
            Transparency = 0.8,
            Visible = false
        }),
        ground_circle_lines = {}
    }
end

local function draw_ground_circle(position, radius, color, steps)
    steps = steps or 18
    local pi = math.pi
    local lines = {}

    local cos_cache = {}
    local sin_cache = {}
    for i = 0, steps do
        local angle = (2 * pi * i) / steps
        cos_cache[i] = math.cos(angle)
        sin_cache[i] = math.sin(angle)
    end

    local points = {}
    for i = 0, steps do
        points[i] = {
            x = position.x + radius * cos_cache[i],
            y = position.y,
            z = position.z + radius * sin_cache[i]
        }
    end

    for i = 0, steps - 1 do
        local point1 = points[i]
        local point2 = points[i + 1]

        local screen1, onScreen1 = worldtoscreen({point1.x, point1.y, point1.z})
        local screen2, onScreen2 = worldtoscreen({point2.x, point2.y, point2.z})

        if screen1 and screen2 and onScreen1 and onScreen2 then
            local line = draw('Line', {
                From = {screen1.x, screen1.y},
                To = {screen2.x, screen2.y},
                Color = color,
                Thickness = 1,
                Transparency = 0.7,
                Visible = true
            })
            table.insert(lines, line)
        end
    end

    return lines
end

local function SafeGetPosition(part)
    if not part then return nil end

    local success, pos = pcall(function()
        return getposition(part)
    end)

    if success and pos then
        return {pos.x, pos.y, pos.z}
    end
    return nil
end

local function isBeast(character)
    if not character then return false end
    local hammer = findfirstchild(character, "Hammer")
    return hammer ~= nil
end

local function get_player_drawing_objects(player_key, character)
    local player_objects = player_data_cache[player_key]
    local is_beast = isBeast(character)
    local settings = is_beast and config.beast or config.player

    if not player_objects.DrawingLines then
        player_objects.DrawingLines = {}
        for i = 1, MAX_LINES do
            local line_obj
            if #line_pool > 0 then
                line_obj = table.remove(line_pool)
            else
                line_obj = Drawing.new("Line")
                line_obj.Thickness = settings.line_thickness
                line_obj.Color = settings.color
                line_obj.zIndex = 1
            end
            line_obj.Visible = false
            table.insert(player_objects.DrawingLines, line_obj)
        end
    else

        for _, line in ipairs(player_objects.DrawingLines) do
            line.Color = settings.color
            line.Thickness = settings.line_thickness
        end
    end

    if not player_objects.NameText then
        if #text_pool > 0 then
            player_objects.NameText = table.remove(text_pool)
        else
            player_objects.NameText = Drawing.new("Text")
            player_objects.NameText.Size = settings.text_size
            player_objects.NameText.Color = settings.color
            player_objects.NameText.Center = true
            player_objects.NameText.Outline = true
            player_objects.NameText.OutlineColor = {0, 0, 0}
            player_objects.NameText.zIndex = 1
        end
        player_objects.NameText.Visible = false
    else

        player_objects.NameText.Color = settings.color
        player_objects.NameText.Size = settings.text_size
    end

    return player_objects.DrawingLines, player_objects.NameText, settings
end

local function release_player_drawing_objects(player_key)
    if player_data_cache[player_key] then
        if player_data_cache[player_key].DrawingLines then
            for _, line_obj in ipairs(player_data_cache[player_key].DrawingLines) do
                line_obj.Visible = false
                table.insert(line_pool, line_obj)
            end
            player_data_cache[player_key].DrawingLines = nil
        end

        if player_data_cache[player_key].NameText then
            player_data_cache[player_key].NameText.Visible = false
            table.insert(text_pool, player_data_cache[player_key].NameText)
            player_data_cache[player_key].NameText = nil
        end
    end
end

local function update_skeleton_esp()
    local campos = getpos(camera)

    while not stop do
        local all_players = getchildren(players)
        local current_frame_drawn_player_count = 0

        for player_key in pairs(player_data_cache) do
            player_data_cache[player_key].IsCurrentlyActive = false
        end

        if all_players then
            for _, player in ipairs(all_players) do
                if player == localplayer then 
                    continue 
                end

                local character = getcharacter(player)
                if not character then 
                    continue 
                end

                local humanoid = findfirstchild(character, "Humanoid")
                if not humanoid then 
                    continue 
                end

                local player_key = getname(player)
                local is_beast = isBeast(character)
                local settings = is_beast and config.beast or config.player

                if not settings.enabled then
                    continue
                end

                if not player_data_cache[player_key] then
                    player_data_cache[player_key] = {
                        Character = character,
                        IsAlive = true,
                        IsBeast = is_beast
                    }
                else

                    player_data_cache[player_key].IsBeast = is_beast
                    player_data_cache[player_key].Character = character
                end

                local current_player_data = player_data_cache[player_key]
                current_player_data.IsCurrentlyActive = true

                local player_lines, name_text, settings = get_player_drawing_objects(player_key, character)

                local head = findfirstchild(character, "Head")
                if head and settings.show_names then
                    local head_pos = SafeGetPosition(head)
                    if head_pos then
                        local screen_pos, visible = worldtoscreenpoint(head_pos)
                        if visible then

                            name_text.Text = getname(player)
                            name_text.Position = {screen_pos.x, screen_pos.y - settings.name_y_offset}
                            name_text.Size = settings.text_size
                            name_text.Visible = true
                        else
                            name_text.Visible = false
                        end
                    else
                        name_text.Visible = false
                    end
                else
                    name_text.Visible = false
                end

                if settings.show_skeleton then
                    for line_idx, conn_pair in ipairs(CONNECTIONS) do
                        local line_obj = player_lines[line_idx]
                        local part1 = findfirstchild(character, conn_pair[1])
                        local part2 = findfirstchild(character, conn_pair[2])

                        if part1 and part2 then
                            local pos1 = SafeGetPosition(part1)
                            local pos2 = SafeGetPosition(part2)

                            if pos1 and pos2 then
                                local s1, v1 = worldtoscreenpoint(pos1)
                                local s2, v2 = worldtoscreenpoint(pos2)

                                if v1 and v2 then
                                    line_obj.From = {s1.x, s1.y}
                                    line_obj.To = {s2.x, s2.y}
                                    line_obj.Thickness = settings.line_thickness
                                    line_obj.Color = settings.color
                                    line_obj.Visible = true
                                else
                                    line_obj.Visible = false
                                end
                            else
                                line_obj.Visible = false
                            end
                        else
                            line_obj.Visible = false
                        end
                    end
                else

                    for _, line_obj in ipairs(player_lines) do
                        line_obj.Visible = false
                    end
                end

                current_frame_drawn_player_count = current_frame_drawn_player_count + 1
            end
        end

        local keys_to_remove = {}
        for player_key, data in pairs(player_data_cache) do
            if not data.IsCurrentlyActive then
                release_player_drawing_objects(player_key)
                table.insert(keys_to_remove, player_key)
            end
        end

        for _, key_to_del in ipairs(keys_to_remove) do
            player_data_cache[key_to_del] = nil
        end

        wait(RENDER_STEP)
    end
end

local function isMapModel(model)
    local modelName = getname(model)
    if string.find(modelName:lower(), "by") then
        if not ignoreModels[modelName] then
        return true
        end
    end
    return false
end

local function findComputerTables(mapModel)
    if not mapModel then return {} end

    local mapId = tostring(mapModel)
    if computerCache[mapId] then
        return computerCache[mapId]
    end

    local computers = {}
    for _, model in pairs(getchildren(mapModel)) do
        if getclassname(model) == "Model" and getname(model) == "ComputerTable" then
            local representativePart = nil

            for _, part in pairs(getchildren(model)) do
                if getclassname(part) == "Part" then
                    representativePart = part
                    break
            end
        end

            if representativePart then
                computers[tostring(model)] = {
                    model = model,
                    part = representativePart,
                    esp = {
                        text = Drawing.new("Text"),
                        distanceText = Drawing.new("Text")
                    }
                }

                local esp = computers[tostring(model)].esp
                esp.text.Size = config.computer.text_size
                esp.text.Center = true
                esp.text.Outline = true
                esp.text.Color = config.computer.color
                esp.text.Visible = false

                esp.distanceText.Size = config.computer.text_size
                esp.distanceText.Center = true
                esp.distanceText.Outline = true
                esp.distanceText.Color = config.computer.color
                esp.distanceText.Visible = false
            end
            end
        end

    computerCache[mapId] = computers
    return computers
end

local function findMaps()
    local foundMaps = {}

        for _, model in pairs(getchildren(workspace)) do
            if getclassname(model) == "Model" and isMapModel(model) and isdescendantof(model, workspace) then
                local modelName = getname(model)
                foundMaps[modelName] = model
        end
    end

    return foundMaps
end

local function updateComputerESP(computerData, localPos3D)
    if not config.computer.enabled then
        computerData.esp.text.Visible = false
        computerData.esp.distanceText.Visible = false
        return
    end

    local parent = getparent(computerData.model)
    if not computerData.model or not computerData.part or not parent then
        computerData.esp.text.Visible = false
        computerData.esp.distanceText.Visible = false
        return
    end

    if not isdescendantof(computerData.model, workspace) then
        computerData.esp.text.Visible = false
        computerData.esp.distanceText.Visible = false
        return
    end

    local pos3D = getposition(computerData.part)
    if not pos3D then
        computerData.esp.text.Visible = false
        computerData.esp.distanceText.Visible = false
        return
    end

    local pos2D, onScreen = worldtoscreenpoint({pos3D.x, pos3D.y, pos3D.z})
    if not onScreen then
        computerData.esp.text.Visible = false
        computerData.esp.distanceText.Visible = false
        return
    end

    local dx = pos3D.x - localPos3D.x
    local dy = pos3D.y - localPos3D.y
    local dz = pos3D.z - localPos3D.z
    local distance = math.round(math.sqrt(dx*dx + dy*dy + dz*dz))

    if config.computer.show_names then
        computerData.esp.text.Position = {pos2D.x, pos2D.y - config.computer.name_y_offset}
        computerData.esp.text.Text = "pc"
        computerData.esp.text.Size = config.computer.text_size
        computerData.esp.text.Color = config.computer.color
        computerData.esp.text.Visible = true
    else
        computerData.esp.text.Visible = false
    end

    if config.computer.show_distance then
        computerData.esp.distanceText.Position = {pos2D.x, pos2D.y + config.computer.distance_y_offset}
        computerData.esp.distanceText.Text = "D: " .. distance
        computerData.esp.distanceText.Size = config.computer.text_size
        computerData.esp.distanceText.Color = config.computer.color
        computerData.esp.distanceText.Visible = true
    else
        computerData.esp.distanceText.Visible = false
    end
end

local function updateAllComputerESP()
    local localPlayer = getlocalplayer()
    local localChar = getcharacter(localPlayer)
    if not localChar then return end

    local localRoot = findfirstchild(localChar, "HumanoidRootPart")
    if not localRoot then return end

    local localPos3D = getposition(localRoot)
    if not localPos3D then return end

    local hasValidComputers = false
    for mapId, computers in pairs(computerCache) do
        for _, computerData in pairs(computers) do
            if computerData.model and computerData.part and isdescendantof(computerData.model, workspace) then
                hasValidComputers = true
                updateComputerESP(computerData, localPos3D)
            end
        end
    end

    if not hasValidComputers then
        local maps = findMaps()
        for _, mapModel in pairs(maps) do
            if isdescendantof(mapModel, workspace) then
                local computers = findComputerTables(mapModel)
                if next(computers) then
                    computerCache[tostring(mapModel)] = computers

                    for _, computerData in pairs(computers) do
                        updateComputerESP(computerData, localPos3D)
                    end
                end
            end
        end
    end
end

local function deepCleanup()

    for player_key, data in pairs(player_data_cache) do
        release_player_drawing_objects(player_key)
    end
    player_data_cache = {}

    for mapId, computers in pairs(computerCache) do
        for _, computerData in pairs(computers) do
            if computerData.esp then
                computerData.esp.text:Remove()
                computerData.esp.distanceText:Remove()
            end
        end
    end
    computerCache = {}

    for mapId, freezePods in pairs(freezePodCache) do
        for _, podData in pairs(freezePods) do
            if podData.esp then
                podData.esp.text:Remove()
                podData.esp.distanceText:Remove()
            end
        end
    end
    freezePodCache = {}

    for _, line in ipairs(line_pool) do
        line:Remove()
    end
    line_pool = {}

    for _, text in ipairs(text_pool) do
        text:Remove()
    end
    text_pool = {}

    if gcinfo then
        warn("Performing deep cleanup - Memory usage: " .. gcinfo() .. " KB")
    end
end

local function cleanupCache()
    while not stop do

        for mapId, computers in pairs(computerCache) do
            local validComputers = {}
            local hasValid = false

            for id, computerData in pairs(computers) do
                if computerData.model and computerData.part and isdescendantof(computerData.model, workspace) then
                    validComputers[id] = computerData
                    hasValid = true
                else
                    if computerData.esp then
                        computerData.esp.text:Remove()
                        computerData.esp.distanceText:Remove()
                    end
                end
            end

            if not hasValid then
                computerCache[mapId] = nil
            else
                computerCache[mapId] = validComputers
            end
        end

        for mapId, freezePods in pairs(freezePodCache) do
            local validPods = {}
            local hasValid = false

            for id, podData in pairs(freezePods) do
                if podData.model and podData.part and isdescendantof(podData.model, workspace) then
                    validPods[id] = podData
                    hasValid = true
                else
                    if podData.esp then
                        podData.esp.text:Remove()
                        podData.esp.distanceText:Remove()
                    end
                end
            end

            if not hasValid then
                freezePodCache[mapId] = nil
            else
                freezePodCache[mapId] = validPods
            end
        end

        local keys_to_remove = {}
        for player_key, data in pairs(player_data_cache) do
            if not data.IsCurrentlyActive then
                release_player_drawing_objects(player_key)
                table.insert(keys_to_remove, player_key)
            end
        end

        for _, key_to_del in ipairs(keys_to_remove) do
            player_data_cache[key_to_del] = nil
        end

        if tick() - lastUpdate > 300 then
            deepCleanup()
            lastUpdate = tick()
        end

        wait(2) 
    end
end

local function findFreezePods(mapModel)
    if not mapModel then return {} end

    local mapId = tostring(mapModel)
    if freezePodCache[mapId] then
        return freezePodCache[mapId]
    end

    local freezePods = {}

    local function findRepresentativePart(model)
        local partNames = {"Part", "BasePart", "Barrier", "PodTrigger"}
        local foundPart = nil

        for _, partName in ipairs(partNames) do
            for _, part in pairs(getchildren(model)) do
                if getclassname(part) == "Part" and getname(part) == partName then
                    foundPart = part
                    break
                end
            end
            if foundPart then break end
        end

        return foundPart
    end

    local function searchInModel(model)

        if getclassname(model) == "Model" and getname(model) == "FreezePod" then
            local representativePart = findRepresentativePart(model)

            if representativePart then
                freezePods[tostring(model)] = {
                    model = model,
                    part = representativePart,
                    esp = {
                        text = Drawing.new("Text"),
                        distanceText = Drawing.new("Text")
                    }
                }

                local esp = freezePods[tostring(model)].esp
                esp.text.Size = config.freezepod.text_size
                esp.text.Center = true
                esp.text.Outline = true
                esp.text.Color = config.freezepod.color
                esp.text.Visible = false

                esp.distanceText.Size = config.freezepod.text_size
                esp.distanceText.Center = true
                esp.distanceText.Outline = true
                esp.distanceText.Color = config.freezepod.color
                esp.distanceText.Visible = false
        end
    end

        for _, child in pairs(getchildren(model)) do
            if getclassname(child) == "Model" then
                searchInModel(child)
        end
    end
    end

    searchInModel(mapModel)

    freezePodCache[mapId] = freezePods
    return freezePods
end

local function updateFreezePodESP(freezePodData, localPos3D)
    if not config.freezepod.enabled then
        freezePodData.esp.text.Visible = false
        freezePodData.esp.distanceText.Visible = false
        return
    end

    local parent = getparent(freezePodData.model)
    if not freezePodData.model or not freezePodData.part or not parent then
        freezePodData.esp.text.Visible = false
        freezePodData.esp.distanceText.Visible = false
        return
    end

    if not isdescendantof(freezePodData.model, workspace) then
        freezePodData.esp.text.Visible = false
        freezePodData.esp.distanceText.Visible = false
        return
    end

    local pos3D = getposition(freezePodData.part)
    if not pos3D then
        freezePodData.esp.text.Visible = false
        freezePodData.esp.distanceText.Visible = false
        return
    end

    local pos2D, onScreen = worldtoscreenpoint({pos3D.x, pos3D.y, pos3D.z})
    if not onScreen then
        freezePodData.esp.text.Visible = false
        freezePodData.esp.distanceText.Visible = false
        return
    end

    local dx = pos3D.x - localPos3D.x
    local dy = pos3D.y - localPos3D.y
    local dz = pos3D.z - localPos3D.z
    local distance = math.round(math.sqrt(dx*dx + dy*dy + dz*dz))

    if config.freezepod.show_names then
        freezePodData.esp.text.Position = {pos2D.x, pos2D.y - config.freezepod.name_y_offset}
        freezePodData.esp.text.Text = "pod"
        freezePodData.esp.text.Size = config.freezepod.text_size
        freezePodData.esp.text.Color = config.freezepod.color
        freezePodData.esp.text.Visible = true
    else
        freezePodData.esp.text.Visible = false
    end

    if config.freezepod.show_distance then
        freezePodData.esp.distanceText.Position = {pos2D.x, pos2D.y + config.freezepod.distance_y_offset}
        freezePodData.esp.distanceText.Text = "D: " .. distance
        freezePodData.esp.distanceText.Size = config.freezepod.text_size
        freezePodData.esp.distanceText.Color = config.freezepod.color
        freezePodData.esp.distanceText.Visible = true
    else
        freezePodData.esp.distanceText.Visible = false
    end
end

local function updateAllFreezePodESP()
    local localPlayer = getlocalplayer()
    local localChar = getcharacter(localPlayer)
    if not localChar then return end

    local localRoot = findfirstchild(localChar, "HumanoidRootPart")
    if not localRoot then return end

    local localPos3D = getposition(localRoot)
    if not localPos3D then return end

    local hasValidFreezePods = false
    for mapId, freezePods in pairs(freezePodCache) do
        for _, freezePodData in pairs(freezePods) do
            if freezePodData.model and freezePodData.part and isdescendantof(freezePodData.model, workspace) then
                hasValidFreezePods = true
                updateFreezePodESP(freezePodData, localPos3D)
            end
        end
    end

    if not hasValidFreezePods then
        local maps = findMaps()
        for _, mapModel in pairs(maps) do
            if isdescendantof(mapModel, workspace) then
                local freezePods = findFreezePods(mapModel)
                if next(freezePods) then
                    freezePodCache[tostring(mapModel)] = freezePods

                    for _, freezePodData in pairs(freezePods) do
                        updateFreezePodESP(freezePodData, localPos3D)
                    end
                end
            end
        end
    end
end

spawn(update_skeleton_esp)
spawn(cleanupCache)

spawn(function()
    while not stop do
        updateAllComputerESP()
        updateAllFreezePodESP()
        wait(0.01)
    end
end)

spawn(function()
    while not stop do
        wait(300) 
        warn("Performing periodic deep cleanup to prevent lag")
        deepCleanup()
    end
end)

local function monitorGame()
    local SCRIPT_URL = "https://raw.githubusercontent.com/junior6913/p/refs/heads/main/t"

    spawn(function()

        local mapIsPresent = true
        while mapIsPresent do
            wait(5) 
            local maps = findMaps()
            if not next(maps) then
                mapIsPresent = false
            end
        end

        warn("Map unloaded. Cleaning up ESP...")
        stop = true 
        wait(0.5) 
        deepCleanup()
        Drawing.clear() 

        warn("Waiting for a new map to load...")
        local newMapFound = false
        while not newMapFound do
            wait(1) 
            local maps = findMaps()
            if next(maps) then
                newMapFound = true
            end
        end

        warn("New map detected. Reloading script...")
        local success, script_code = pcall(httpget, SCRIPT_URL)
        if success and script_code then
            local func, err = loadstring(script_code)
            if func then
                spawn(func)
            else
                warn("Error loading script: " .. tostring(err))
            end
        else
            warn("Failed to download script from URL: " .. tostring(script_code))
        end
    end)
end

monitorGame()
