-- ollama roblox chat
-- needs ollama running locally + starlight ui
-- works on most executors (synapse, krnl, fluxus, wave, etc.)

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

-- grab whatever http function ur executor has
local http_request = http_request or request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)
if not http_request then
    warn("[Ollama] ur executor doesnt support http requests lol")
    return
end

local Starlight = loadstring(game:HttpGet("https://raw.nebulasoftworks.xyz/starlight"))()
local NebulaIcons = loadstring(game:HttpGet("https://raw.nebulasoftworks.xyz/nebula-icon-library-loader"))()

-- settings
local Settings = {
    Model = "qwen2.5:7b",
    Temperature = 0.7,
    MaxMemory = 50,
    Streaming = false,
    TypingAnimation = true,
    AutoScroll = true,
    SoundEffects = false,
    ProximityPrefix = "[AI]",
    ProximityRadius = 50,
    AutoRespond = true,
    ResponseDelay = 1.5,
    IgnoredPlayers = {},
    OllamaURL = "http://localhost:11434",
}

-- chat history n stuff
local PrivateMessages = {}
local ProximityMessages = {}
local ProximityMemory = {}
local CurrentPreset = "Friendly Assistant"
local CustomPrompt = ""
local UseCustomPrompt = false
local isProcessing = false

-- personalities (edit these if u want)
local Presets = {
    ["Friendly Assistant"] = "You are a friendly AI in Roblox. Keep replies short and chill.",
    ["Roblox Guide"] = "You know everything about Roblox. Help players out, be cool about it.",
    ["Storyteller"] = "You narrate everything like a story. Be dramatic, describe stuff.",
    ["Fantasy NPC"] = "Youre a medieval fantasy NPC. Say 'traveler', 'adventurer', 'aye', 'good sir'.",
    ["Medieval Knight"] = "Youre a noble knight. Use 'thy', 'thou', 'forsooth'. Defend the innocent.",
    ["Pirate Captain"] = "Arr matey. Youre a pirate captain. Say arr, ye, shiver me timbers.",
    ["Sci-Fi Android"] = "Youre a futuristic android. Speak precise, reference circuits n data.",
    ["Detective"] = "Youre a detective. Analyze everything, say Elementary, case closed.",
    ["Wizard"] = "Youre an ancient wizard. Say ah yes, by the stars. Be wise and cryptic.",
    ["Merchant"] = "Youre a traveling merchant. Always try to sell stuff. ah a customer!",
    ["Villager"] = "Simple villager. Say hmm, oh dear. Talk about crops and village gossip.",
    ["Survival Companion"] = "Help players survive. Short urgent messages. Warn about dangers.",
    ["Dungeon Master"] = "DM narrating a tabletop RPG. Describe rooms, create encounters.",
    ["Horror Character"] = "Eerie mysterious character. Speak in unsettling whispers. Create tension.",
    ["Comedian"] = "Stand-up comedian in Roblox. Tell jokes, be witty, make puns.",
}

-- http wrapper that works on basically every executor
local function makeRequest(url, method, body)
    local req = {
        Url = url,
        Method = method or "GET",
        Headers = { ["Content-Type"] = "application/json" },
    }
    if body then req.Body = body end

    local ok, res = pcall(function() return http_request(req) end)
    if not ok then return nil, "http failed: " .. tostring(res) end

    local bodyOut = res.Body or res.body or res.ResponseBody or res.responseBody or ""
    local status = res.StatusCode or res.statusCode or res.Status or res.status or 0
    return { Body = bodyOut, StatusCode = status }
end

-- call ollama (non-streaming bc executors dont handle streaming well)
local function ollamaChat(messages, callback)
    local payload = HttpService:JSONEncode({
        model = Settings.Model,
        messages = messages,
        stream = false,
        options = { temperature = Settings.Temperature },
    })

    task.spawn(function()
        local res, err = makeRequest(Settings.OllamaURL .. "/api/chat", "POST", payload)
        if not res then
            callback("[Error: " .. (err or "idk") .. "]", true)
            return
        end
        if res.StatusCode == 200 then
            local ok, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
            if ok and parsed.message and parsed.message.content then
                callback(parsed.message.content, true)
            else
                callback("[Error: bad response from ollama]", true)
            end
        else
            callback("[Error: HTTP " .. tostring(res.StatusCode) .. "]", true)
        end
    end)
end

-- check if ollama is alive
local function testOllama(callback)
    task.spawn(function()
        local res, err = makeRequest(Settings.OllamaURL .. "/api/tags", "GET")
        if not res then callback(false, err or "nope") return end
        callback(res.StatusCode == 200, res.StatusCode == 200 and "connected!" or "HTTP " .. tostring(res.StatusCode))
    end)
end

-- get list of installed models
local function listModels(callback)
    task.spawn(function()
        local res = makeRequest(Settings.OllamaURL .. "/api/tags", "GET")
        if not res then callback({}, "no connection") return end
        if res.StatusCode == 200 then
            local ok, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
            if ok and parsed.models then
                local names = {}
                for _, m in ipairs(parsed.models) do table.insert(names, m.name) end
                callback(names, nil)
            else
                callback({}, "couldnt parse")
            end
        else
            callback({}, "HTTP " .. tostring(res.StatusCode))
        end
    end)
end

-- trim message history to max length
local function buildContext(messages, maxLen)
    local out = {}
    local start = math.max(1, #messages - maxLen + 1)
    for i = start, #messages do table.insert(out, messages[i]) end
    return out
end

-- get current system prompt
local function getSystemPrompt()
    if UseCustomPrompt and CustomPrompt ~= "" then return CustomPrompt end
    return Presets[CurrentPreset] or Presets["Friendly Assistant"]
end

-- distance between two positions
local function getDistance(a, b) return (a - b).Magnitude end

-- figure out which player sent a message (differs per executor)
local function getPlayerFromMessage(message)
    pcall(function()
        local ts = message.TextSource
        if ts and ts.UserId and ts.UserId > 0 then
            local p = Players:GetPlayerByUserId(ts.UserId)
            if p then return p end
        end
    end)
    return nil
end

-- is player close enough
local function isPlayerInRadius(player)
    if not Settings.AutoRespond then return false end
    local myChar = LocalPlayer.Character
    local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Head"))
    if not myRoot then return false end
    local theirChar = player.Character
    local theirRoot = theirChar and (theirChar:FindFirstChild("HumanoidRootPart") or theirChar:FindFirstChild("Head"))
    if not theirRoot then return false end
    return getDistance(myRoot.Position, theirRoot.Position) <= Settings.ProximityRadius
end

local function isPlayerIgnored(player)
    return Settings.IgnoredPlayers[player.UserId] == true
end

-- send message in game chat
local function sendProximityChat(text)
    local ok = pcall(function()
        local ch = TextChatService:FindFirstChild("TextChannels")
        if ch then
            local gen = ch:FindFirstChild("RBXGeneral")
            if gen then gen:SendAsync(text) return end
        end
    end)
    if ok then return end
    -- fallback for old chat system
    pcall(function()
        local ev = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
        if ev then
            local say = ev:FindFirstChild("SayMessageRequest")
            if say then say:FireServer(text, "All") end
        end
    end)
end

-- typing dots animation
local function typingAnim(paragraph, label, duration)
    local dots = {"", ".", "..", "..."}
    local i, elapsed, alive = 1, 0, true
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not alive then return end
        elapsed = elapsed + dt
        if elapsed >= duration then alive = false; conn:Disconnect() return end
        i = (i % #dots) + 1
        pcall(function() paragraph:Set({ Content = "Typing" .. dots[i] }) end)
    end)
    return { Disconnect = function()
        alive = false
        if conn and conn.Connected then conn:Disconnect() end
    end }
end

-- format proximity log for display
local function formatProximityDisplay()
    if #ProximityMessages == 0 then return "waiting for someone to talk nearby..." end
    local txt = table.concat(ProximityMessages, "\n")
    local lines = {}
    for line in txt:gmatch("[^\n]+") do table.insert(lines, line) end
    if #lines > 30 then
        local t = {}
        for i = #lines - 29, #lines do table.insert(t, lines[i]) end
        txt = table.concat(t, "\n")
    end
    return txt
end

-- format private chat for display
local function formatPrivateDisplay()
    if #PrivateMessages == 0 then return "nothing here yet. type something below!" end
    local parts = {}
    for _, msg in ipairs(PrivateMessages) do
        table.insert(parts, (msg.role == "user" and "[You]: " or "[AI]: ") .. msg.content)
    end
    local txt = table.concat(parts, "\n")
    local lines = {}
    for line in txt:gmatch("[^\n]+") do table.insert(lines, line) end
    if #lines > 40 then
        local t = {}
        for i = #lines - 39, #lines do table.insert(t, lines[i]) end
        txt = table.concat(t, "\n")
    end
    return txt
end

-- ========================================
-- UI SETUP
-- ========================================
local Window = Starlight:CreateWindow({
    Name = "Ollama AI",
    Subtitle = "local AI for roblox",
    LoadingSettings = {
        Title = "Ollama AI",
        Subtitle = "connecting...",
    },
    FileSettings = {
        ConfigFolder = "OllamaAI",
    },
})

-- ========================================
-- TAB 1: PRIVATE CHAT
-- ========================================
local ChatTabSection = Window:CreateTabSection("Chat")
local PrivateTab = ChatTabSection:CreateTab({
    Name = "Private Chat",
    Icon = NebulaIcons:GetIcon("chat", "Material"),
    Columns = 1,
})

local PrivateGroup = PrivateTab:CreateGroupbox({
    Name = "Private AI Chat",
    Column = 1,
})

PrivateGroup:CreateLabel({ Name = "only you can see these messages. press enter to send." })
PrivateGroup:CreateDivider()

local PrivateMessagesParagraph = PrivateGroup:CreateParagraph({
    Name = "Chat",
    Content = "nothing here yet. type something below!",
})

PrivateGroup:CreateDivider()

local PrivateInput = PrivateGroup:CreateInput({
    Name = "Message",
    CurrentValue = "",
    PlaceholderText = "say something...",
    MaxCharacters = 500,
    Enter = true,
    Callback = function(text)
        if text == "" then return end

        table.insert(PrivateMessages, { role = "user", content = text })
        PrivateMessagesParagraph:Set({ Content = formatPrivateDisplay() })

        local typing = nil
        if Settings.TypingAnimation then
            typing = typingAnim(PrivateMessagesParagraph, "Chat", 60)
        end

        local apiMessages = { { role = "system", content = getSystemPrompt() } }
        local context = buildContext(PrivateMessages, Settings.MaxMemory)
        for _, msg in ipairs(context) do
            table.insert(apiMessages, { role = msg.role, content = msg.content })
        end

        ollamaChat(apiMessages, function(response, done)
            if done then
                if typing then typing:Disconnect() end
                table.insert(PrivateMessages, { role = "assistant", content = response })
                PrivateMessagesParagraph:Set({ Content = formatPrivateDisplay() })
            end
        end)

        PrivateInput:Set({ CurrentValue = "" })
    end,
}, "PrivateMsgInput")

PrivateGroup:CreateDivider()

PrivateGroup:CreateButton({
    Name = "Clear Conversation",
    Callback = function()
        PrivateMessages = {}
        PrivateMessagesParagraph:Set({ Content = "wiped." })
        Starlight:Notification({ Title = "cleared", Content = "private chat history gone" })
    end,
})

PrivateGroup:CreateButton({
    Name = "Export Chat",
    Callback = function()
        local text = ""
        for _, msg in ipairs(PrivateMessages) do
            text = text .. (msg.role == "user" and "You: " or "AI: ") .. msg.content .. "\n"
        end
        if setclipboard then
            setclipboard(text)
        elseif syn and syn.write_clipboard then
            syn.write_clipboard(text)
        end
        Starlight:Notification({ Title = "copied", Content = "chat copied to clipboard" })
    end,
})

-- ========================================
-- TAB 2: PROXIMITY CHAT
-- ========================================
local ProximityTab = ChatTabSection:CreateTab({
    Name = "Proximity Chat",
    Icon = NebulaIcons:GetIcon("record_voice_over", "Material"),
    Columns = 1,
})

local ProximityGroup = ProximityTab:CreateGroupbox({
    Name = "Auto AI Responses",
    Column = 1,
})

ProximityGroup:CreateLabel({ Name = "when someone near you chats, the AI replies in game chat" })
ProximityGroup:CreateDivider()

local ProximityMessagesParagraph = ProximityGroup:CreateParagraph({
    Name = "Activity Log",
    Content = "waiting for someone to talk nearby...",
})

ProximityGroup:CreateDivider()

local ProximityStatusParagraph = ProximityGroup:CreateParagraph({
    Name = "Status",
    Content = "auto: ON | radius: 50 studs | nearby: 0 | blacklisted: 0",
})

ProximityGroup:CreateDivider()

ProximityGroup:CreateLabel({ Name = "Manual Input" })

ProximityGroup:CreateInput({
    Name = "Say Something",
    CurrentValue = "",
    PlaceholderText = "type to send as AI manually...",
    MaxCharacters = 500,
    Enter = true,
    Callback = function(text)
        if text == "" then return end
        local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. text) or text
        sendProximityChat(chatText)
        table.insert(ProximityMessages, "[Manual]: " .. text)
        ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })
    end,
}, "ProximityManualInput")

ProximityGroup:CreateButton({
    Name = "Clear Log",
    Callback = function()
        ProximityMessages = {}
        ProximityMessagesParagraph:Set({ Content = "log cleared." })
    end,
})

-- quick say dropdown nested in a label
local QuickSayLabel = ProximityGroup:CreateLabel({ Name = "Quick Say" })
QuickSayLabel:AddDropdown({
    Options = {"Hello everyone!","Anyone wanna play?","GG!","Nice!","Good luck!","Thanks!","Let's go!","Follow me!","Wait for me!","I'll help!"},
    CurrentOption = {"Hello everyone!"},
    Callback = function(opts)
        local text = opts[1]
        if not text then return end
        local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. text) or text
        sendProximityChat(chatText)
        table.insert(ProximityMessages, "[Quick]: " .. text)
        ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })
    end,
}, "QuickSayDD")

-- ========================================
-- PROXIMITY CHAT: Listen for nearby messages
-- ========================================
local function setupProximityListener()
    local success = pcall(function()
        local ch = TextChatService:FindFirstChild("TextChannels")
        if not ch then return false end
        local gen = ch:FindFirstChild("RBXGeneral")
        if not gen then return false end

        gen.MessageReceived:Connect(function(message)
            local ok, err = pcall(function()
                if isProcessing then return end
                if not Settings.AutoRespond then return end

                local sender = getPlayerFromMessage(message)
                if not sender then return end
                if sender == LocalPlayer then return end
                if isPlayerIgnored(sender) then return end
                if not isPlayerInRadius(sender) then return end

                local msgText = message.Text
                if not msgText or msgText == "" then return end

                isProcessing = true

                table.insert(ProximityMessages, "[" .. sender.Name .. "]: " .. msgText)
                ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })

                task.delay(Settings.ResponseDelay, function()
                    local typing = nil
                    if Settings.TypingAnimation then
                        typing = typingAnim(ProximityMessagesParagraph, "Activity Log", 60)
                    end

                    local apiMessages = {
                        { role = "system", content = getSystemPrompt() .. "\n\nYoure chatting in a Roblox game. A player named " .. sender.Name .. ' said: "' .. msgText .. '". Reply like a real player. Keep it SHORT (under 80 chars). No markdown, no code blocks, just be natural.' },
                    }
                    local context = buildContext(ProximityMemory, math.min(Settings.MaxMemory, 20))
                    for _, msg in ipairs(context) do
                        table.insert(apiMessages, { role = msg.role, content = msg.content })
                    end
                    table.insert(apiMessages, { role = "user", content = sender.Name .. ": " .. msgText })

                    ollamaChat(apiMessages, function(response, done)
                        if done then
                            if typing then typing:Disconnect() end

                            if not response:match("^%[Error") then
                                local clean = response:gsub("\n", " "):gsub("%*%*", ""):gsub("`[^`]*`", ""):sub(1, 200)
                                local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. clean) or clean
                                sendProximityChat(chatText)

                                table.insert(ProximityMessages, "[AI -> " .. sender.Name .. "]: " .. clean)
                                table.insert(ProximityMemory, { role = "user", content = sender.Name .. ": " .. msgText })
                                table.insert(ProximityMemory, { role = "assistant", content = clean })

                                if #ProximityMemory > Settings.MaxMemory then
                                    local trimmed = {}
                                    for i = #ProximityMemory - Settings.MaxMemory + 1, #ProximityMemory do
                                        table.insert(trimmed, ProximityMemory[i])
                                    end
                                    ProximityMemory = trimmed
                                end
                            else
                                table.insert(ProximityMessages, "[AI Error]: " .. response)
                            end

                            ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })
                            isProcessing = false
                        end
                    end)
                end)
            end)

            if not ok then
                isProcessing = false
                warn("[Ollama] proximity listener error: " .. tostring(err))
            end
        end)

        return true
    end)

    if not success then
        -- old chat system fallback
        pcall(function()
            local ev = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
            if ev then
                local onMsg = ev:FindFirstChild("OnNewMessage")
                if onMsg then
                    onMsg.OnClientEvent:Connect(function(_, msgData)
                        pcall(function()
                            if isProcessing then return end
                            if not Settings.AutoRespond then return end

                            local name = msgData.FromSpeaker
                            if not name or name == LocalPlayer.Name then return end
                            local plr = Players:FindFirstChild(name)
                            if not plr then return end
                            if isPlayerIgnored(plr) then return end
                            if not isPlayerInRadius(plr) then return end

                            local msgText = msgData.Message
                            if not msgText or msgText == "" then return end

                            isProcessing = true
                            table.insert(ProximityMessages, "[" .. name .. "]: " .. msgText)
                            ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })

                            task.delay(Settings.ResponseDelay, function()
                                local apiMessages = {
                                    { role = "system", content = getSystemPrompt() .. "\n\nA player named " .. name .. ' said: "' .. msgText .. '". Reply naturally. Short (under 80 chars). No markdown.' },
                                }
                                local context = buildContext(ProximityMemory, math.min(Settings.MaxMemory, 20))
                                for _, msg in ipairs(context) do
                                    table.insert(apiMessages, { role = msg.role, content = msg.content })
                                end
                                table.insert(apiMessages, { role = "user", content = name .. ": " .. msgText })

                                ollamaChat(apiMessages, function(response, done)
                                    if done then
                                        if not response:match("^%[Error") then
                                            local clean = response:gsub("\n", " "):gsub("%*%*", ""):sub(1, 200)
                                            local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. clean) or clean
                                            sendProximityChat(chatText)
                                            table.insert(ProximityMessages, "[AI -> " .. name .. "]: " .. clean)
                                            table.insert(ProximityMemory, { role = "user", content = name .. ": " .. msgText })
                                            table.insert(ProximityMemory, { role = "assistant", content = clean })
                                        else
                                            table.insert(ProximityMessages, "[AI Error]: " .. response)
                                        end
                                        ProximityMessagesParagraph:Set({ Content = formatProximityDisplay() })
                                        isProcessing = false
                                    end
                                end)
                            end)
                        end)
                    end)
                end
            end
        end)
    end
end

-- update the status thing every few seconds
task.spawn(function()
    while true do
        task.wait(3)
        pcall(function()
            local nearby = 0
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and isPlayerInRadius(p) then nearby = nearby + 1 end
            end
            local bl = 0
            for _ in pairs(Settings.IgnoredPlayers) do bl = bl + 1 end
            ProximityStatusParagraph:Set({
                Content = "auto: " .. (Settings.AutoRespond and "ON" or "OFF") .. " | radius: " .. Settings.ProximityRadius .. " studs | nearby: " .. nearby .. " | blacklisted: " .. bl,
            })
        end)
    end
end)

setupProximityListener()

-- ========================================
-- TAB 3: SETTINGS
-- ========================================
local SettingsTabSection = Window:CreateTabSection("Settings")
local SettingsTab = SettingsTabSection:CreateTab({
    Name = "Settings",
    Icon = NebulaIcons:GetIcon("settings", "Material"),
    Columns = 2,
})

-- Connection groupbox
local ConnGroup = SettingsTab:CreateGroupbox({
    Name = "Connection",
    Column = 1,
})

ConnGroup:CreateInput({
    Name = "Ollama URL",
    CurrentValue = Settings.OllamaURL,
    PlaceholderText = "http://localhost:11434",
    Callback = function(text) Settings.OllamaURL = text end,
}, "OllamaURLInput")

ConnGroup:CreateButton({
    Name = "Test Connection",
    Callback = function()
        testOllama(function(ok, msg)
            if ok then
                Starlight:Notification({ Title = "nice", Content = "ollama is running at " .. Settings.OllamaURL })
            else
                Starlight:Notification({ Title = "nope", Content = "cant reach ollama: " .. (msg or "idk why") })
            end
        end)
    end,
})

-- model dropdown nested in a label
local ModelLabel = ConnGroup:CreateLabel({ Name = "Model" })
ModelLabel:AddDropdown({
    Options = { "Loading..." },
    CurrentOption = { Settings.Model },
    Callback = function(opts)
        Settings.Model = opts[1] or Settings.Model
    end,
}, "ModelDD")

ConnGroup:CreateButton({
    Name = "Refresh Models",
    Callback = function()
        listModels(function(models, err)
            if #models > 0 then
                Settings.Model = models[1]
                Starlight:Notification({ Title = "ok", Content = #models .. " model(s) found" })
            else
                Starlight:Notification({ Title = "oops", Content = err or "none found. is ollama running?" })
            end
        end)
    end,
})

-- Generation groupbox
local GenGroup = SettingsTab:CreateGroupbox({
    Name = "Generation",
    Column = 2,
})

GenGroup:CreateSlider({
    Name = "Temperature",
    Range = { 0, 2 },
    Increment = 0.1,
    CurrentValue = Settings.Temperature,
    Callback = function(value) Settings.Temperature = value end,
}, "TempSlider")

GenGroup:CreateSlider({
    Name = "Memory Length",
    Range = { 5, 100 },
    Increment = 5,
    CurrentValue = Settings.MaxMemory,
    Callback = function(value) Settings.MaxMemory = value end,
}, "MemSlider")

-- Display groupbox
local DisplayGroup = SettingsTab:CreateGroupbox({
    Name = "Display",
    Column = 1,
})

DisplayGroup:CreateToggle({
    Name = "Typing Animation",
    CurrentValue = Settings.TypingAnimation,
    Callback = function(value) Settings.TypingAnimation = value end,
}, "TypingToggle")

DisplayGroup:CreateToggle({
    Name = "Auto-Scroll",
    CurrentValue = Settings.AutoScroll,
    Callback = function(value) Settings.AutoScroll = value end,
}, "ScrollToggle")

-- Proximity groupbox
local ProxGroup = SettingsTab:CreateGroupbox({
    Name = "Proximity Chat",
    Column = 2,
})

ProxGroup:CreateToggle({
    Name = "Auto-Respond",
    CurrentValue = Settings.AutoRespond,
    Callback = function(value)
        Settings.AutoRespond = value
        Starlight:Notification({ Title = "auto-respond", Content = value and "on" or "off" })
    end,
}, "AutoRespToggle")

ProxGroup:CreateSlider({
    Name = "Proximity Radius",
    Range = { 5, 500 },
    Increment = 1,
    CurrentValue = Settings.ProximityRadius,
    Callback = function(value) Settings.ProximityRadius = value end,
}, "RadiusSlider")

ProxGroup:CreateInput({
    Name = "Exact Radius",
    CurrentValue = "",
    PlaceholderText = tostring(Settings.ProximityRadius),
    Numeric = true,
    MaxCharacters = 4,
    Callback = function(text)
        local num = tonumber(text)
        if num and num >= 1 and num <= 999 then
            Settings.ProximityRadius = num
            Starlight:Notification({ Title = "ok", Content = "radius: " .. num .. " studs" })
        else
            Starlight:Notification({ Title = "bad", Content = "enter 1-999" })
        end
    end,
}, "ExactRadiusInput")

ProxGroup:CreateSlider({
    Name = "Response Delay",
    Range = { 0, 5 },
    Increment = 0.5,
    CurrentValue = Settings.ResponseDelay,
    Callback = function(value) Settings.ResponseDelay = value end,
}, "DelaySlider")

ProxGroup:CreateInput({
    Name = "Chat Prefix",
    CurrentValue = Settings.ProximityPrefix,
    PlaceholderText = "[AI]",
    MaxCharacters = 20,
    Callback = function(text) Settings.ProximityPrefix = text end,
}, "PrefixInput")

-- Blacklist groupbox (spans both columns)
local BlacklistGroup = SettingsTab:CreateGroupbox({
    Name = "Player Blacklist",
    Column = 1,
})

local BlacklistParagraph = BlacklistGroup:CreateParagraph({
    Name = "Blacklisted Players",
    Content = "none",
})

-- blacklist add dropdown
local BlacklistAddLabel = BlacklistGroup:CreateLabel({ Name = "Add to Blacklist" })
BlacklistAddLabel:AddDropdown({
    Special = 1, -- auto-populate with players
    CurrentOption = {},
    Callback = function(opts)
        local name = opts[1]
        if not name then return end
        local plr = Players:FindFirstChild(name)
        if plr then
            Settings.IgnoredPlayers[plr.UserId] = true
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Content = #list > 0 and table.concat(list, ", ") or "none",
            })
            Starlight:Notification({ Title = "blocked", Content = plr.Name .. " added to blacklist" })
        end
    end,
}, "BlacklistAddDD")

-- blacklist remove dropdown
local BlacklistRemoveLabel = BlacklistGroup:CreateLabel({ Name = "Remove from Blacklist" })
BlacklistRemoveLabel:AddDropdown({
    Special = 1,
    CurrentOption = {},
    Callback = function(opts)
        local name = opts[1]
        if not name then return end
        local plr = Players:FindFirstChild(name)
        if plr and Settings.IgnoredPlayers[plr.UserId] then
            Settings.IgnoredPlayers[plr.UserId] = nil
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Content = #list > 0 and table.concat(list, ", ") or "none",
            })
            Starlight:Notification({ Title = "unblocked", Content = plr.Name .. " removed" })
        end
    end,
}, "BlacklistRemoveDD")

BlacklistGroup:CreateButton({
    Name = "Clear Blacklist",
    Callback = function()
        Settings.IgnoredPlayers = {}
        BlacklistParagraph:Set({ Content = "none" })
        Starlight:Notification({ Title = "cleared", Content = "everyone unblocked" })
    end,
})

BlacklistGroup:CreateButton({
    Name = "Blacklist Everyone",
    Callback = function()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then Settings.IgnoredPlayers[p.UserId] = true end
        end
        local count = 0
        for _ in pairs(Settings.IgnoredPlayers) do count = count + 1 end
        BlacklistParagraph:Set({ Content = count .. " players blocked" })
        Starlight:Notification({ Title = "done", Content = count .. " players blocked" })
    end,
})

-- Roleplay groupbox
local RPGroup = SettingsTab:CreateGroupbox({
    Name = "Roleplay Preset",
    Column = 2,
})

local PresetNames = {}
for name, _ in pairs(Presets) do table.insert(PresetNames, name) end
table.sort(PresetNames)

local PresetLabel = RPGroup:CreateLabel({ Name = "AI Personality" })
PresetLabel:AddDropdown({
    Options = PresetNames,
    CurrentOption = { CurrentPreset },
    Callback = function(opts)
        CurrentPreset = opts[1] or CurrentPreset
        UseCustomPrompt = false
        Starlight:Notification({ Title = "switched", Content = "now using: " .. CurrentPreset })
    end,
}, "PresetDD")

-- Custom prompt groupbox
local PromptGroup = SettingsTab:CreateGroupbox({
    Name = "Custom Prompt",
    Column = 1,
})

PromptGroup:CreateInput({
    Name = "Custom System Prompt",
    CurrentValue = CustomPrompt,
    PlaceholderText = "type here...",
    MaxCharacters = 2000,
    Callback = function(text) CustomPrompt = text end,
}, "CustomPromptInput")

PromptGroup:CreateButton({
    Name = "Apply Custom Prompt",
    Callback = function()
        if CustomPrompt ~= "" then
            UseCustomPrompt = true
            Starlight:Notification({ Title = "applied", Content = "using your custom prompt" })
        else
            Starlight:Notification({ Title = "empty", Content = "write something first" })
        end
    end,
})

PromptGroup:CreateButton({
    Name = "Reset to Preset",
    Callback = function()
        UseCustomPrompt = false
        Starlight:Notification({ Title = "reset", Content = "back to: " .. CurrentPreset })
    end,
})

PromptGroup:CreateButton({
    Name = "View Current Prompt",
    Callback = function()
        local prompt = getSystemPrompt()
        Starlight:Notification({ Title = "prompt", Content = prompt:sub(1, 200) .. (#prompt > 200 and "..." or "") })
    end,
})

-- Server groupbox
local ServerGroup = SettingsTab:CreateGroupbox({
    Name = "Server",
    Column = 2,
})

ServerGroup:CreateButton({
    Name = "Rejoin",
    Callback = function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end,
})

ServerGroup:CreateButton({
    Name = "Server Hop",
    Callback = function()
        pcall(function()
            local res = makeRequest("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100", "GET")
            if res and res.StatusCode == 200 then
                local data = HttpService:JSONDecode(res.Body)
                if data and data.data then
                    for _, srv in ipairs(data.data) do
                        if srv.id ~= game.JobId and srv.playing < srv.maxPlayers then
                            TeleportService:TeleportToPlaceInstance(game.PlaceId, srv.id, LocalPlayer)
                            return
                        end
                    end
                end
            end
            Starlight:Notification({ Title = "nope", Content = "no other servers found" })
        end)
    end,
})

ServerGroup:CreateButton({
    Name = "Copy Job ID",
    Callback = function()
        if setclipboard then
            setclipboard(game.JobId)
        elseif syn and syn.write_clipboard then
            syn.write_clipboard(game.JobId)
        end
        Starlight:Notification({ Title = "copied", Content = game.JobId })
    end,
})

-- Danger zone
local DangerGroup = SettingsTab:CreateGroupbox({
    Name = "Danger Zone",
    Column = 1,
})

DangerGroup:CreateButton({
    Name = "Clear Everything",
    Callback = function()
        PrivateMessages = {}
        ProximityMessages = {}
        ProximityMemory = {}
        CurrentPreset = "Friendly Assistant"
        CustomPrompt = ""
        UseCustomPrompt = false
        Settings.Temperature = 0.7
        Settings.MaxMemory = 50
        Settings.ProximityRadius = 50
        Settings.ResponseDelay = 1.5
        Settings.AutoRespond = true
        Settings.ProximityPrefix = "[AI]"
        Settings.IgnoredPlayers = {}
        PrivateMessagesParagraph:Set({ Content = "wiped." })
        ProximityMessagesParagraph:Set({ Content = "wiped." })
        BlacklistParagraph:Set({ Content = "none" })
        Starlight:Notification({ Title = "gone", Content = "everything reset" })
    end,
})

DangerGroup:CreateButton({
    Name = "Destroy UI",
    Callback = function() Starlight:Destroy() end,
})

-- load models on startup
task.spawn(function()
    listModels(function(models, err)
        if #models > 0 then
            Settings.Model = models[1]
        else
            warn("[Ollama] couldnt load models: " .. (err or "idk"))
        end
    end)
end)

Starlight:Notification({ Title = "Ollama AI", Content = "ready - " .. Settings.OllamaURL .. " | " .. Settings.Model })
