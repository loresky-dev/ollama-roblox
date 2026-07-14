-- ollama roblox chat
-- needs ollama running locally + luna ui
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

local Luna = loadstring(game:HttpGet("https://raw.nebulasoftworks.xyz/luna", true))()

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
        pcall(function() paragraph:Set({ Title = label, Text = "Typing" .. dots[i] }) end)
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

-- setup the ui
local Window = Luna:CreateWindow({
    Name = "Ollama AI",
    Subtitle = "local AI for roblox",
    LogoID = nil,
    LoadingEnabled = true,
    LoadingTitle = "Ollama AI",
    LoadingSubtitle = "connecting...",
    ConfigSettings = { RootFolder = nil, ConfigFolder = "OllamaAI" },
    KeySystem = false,
})

-- ========================================
-- TAB 1: PRIVATE CHAT (nobody sees this but u)
-- ========================================
local PrivateTab = Window:CreateTab({
    Name = "Private Chat",
    Icon = "chat",
    ImageSource = "Material",
    ShowTitle = true,
})

PrivateTab:CreateSection("Private AI Chat")
PrivateTab:CreateParagraph({
    Title = "Private Chat",
    Text = "only you can see these messages. press enter to send.",
})

PrivateTab:CreateDivider()

local PrivateMessagesParagraph = PrivateTab:CreateParagraph({
    Title = "Chat",
    Text = "No messages yet. Type below to start chatting!",
})

PrivateTab:CreateDivider()

local PrivateInput = PrivateTab:CreateInput({
    Name = "Message",
    PlaceholderText = "say something...",
    CurrentValue = "",
    Numeric = false,
    MaxCharacters = 500,
    Enter = true,
    Callback = function(text)
        if text == "" then return end

        table.insert(PrivateMessages, { role = "user", content = text })
        PrivateMessagesParagraph:Set({ Title = "Chat", Text = formatPrivateDisplay() })

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
                PrivateMessagesParagraph:Set({ Title = "Chat", Text = formatPrivateDisplay() })
            end
        end)

        PrivateInput:Set({ CurrentValue = "" })
    end,
}, "PrivateMsg")

PrivateTab:CreateDivider()

PrivateTab:CreateButton({
    Name = "Clear Conversation",
    Callback = function()
        PrivateMessages = {}
        PrivateMessagesParagraph:Set({ Title = "Chat", Text = "Conversation cleared." })
        Luna:Notification({ Title = "Cleared", Content = "Private chat history cleared." })
    end,
})

PrivateTab:CreateButton({
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
        Luna:Notification({ Title = "Copied", Content = "Chat copied to clipboard." })
    end,
})

-- ========================================
-- TAB 2: PROXIMITY CHAT (ai talks to nearby players)
-- ========================================
local ProximityTab = Window:CreateTab({
    Name = "Proximity Chat",
    Icon = "record_voice_over",
    ImageSource = "Material",
    ShowTitle = true,
})

ProximityTab:CreateSection("Auto AI Responses")
ProximityTab:CreateParagraph({
    Title = "how this works",
    Text = "when someone near you chats, the AI replies in game chat automatically. mess with the radius and delay in settings.",
})

ProximityTab:CreateDivider()

local ProximityMessagesParagraph = ProximityTab:CreateParagraph({
    Title = "Activity Log",
    Text = "Waiting for nearby players to chat...",
})

ProximityTab:CreateDivider()

local ProximityStatusParagraph = ProximityTab:CreateParagraph({
    Title = "Status",
    Text = "Auto-Respond: ON | Radius: " .. Settings.ProximityRadius .. " studs | Nearby: 0",
})

ProximityTab:CreateDivider()

ProximityTab:CreateSection("Manual Input")

ProximityTab:CreateInput({
    Name = "Say Something",
    PlaceholderText = "Type to send as AI manually...",
    CurrentValue = "",
    Numeric = false,
    MaxCharacters = 500,
    Enter = true,
    Callback = function(text)
        if text == "" then return end
        local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. text) or text
        sendProximityChat(chatText)
        table.insert(ProximityMessages, "[Manual]: " .. text)
        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })
    end,
}, "ProximityManual")

ProximityTab:CreateButton({
    Name = "Clear Log",
    Callback = function()
        ProximityMessages = {}
        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = "Log cleared." })
    end,
})

ProximityTab:CreateDropdown({
    Name = "Quick Say",
    Options = {"Hello everyone!","Anyone wanna play?","GG!","Nice!","Good luck!","Thanks!","Let's go!","Follow me!","Wait for me!","I'll help!"},
    CurrentOption = { "Hello everyone!" },
    MultipleOptions = false,
    Callback = function(option)
        local text = type(option) == "table" and option[1] or option
        local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. text) or text
        sendProximityChat(chatText)
        table.insert(ProximityMessages, "[Quick]: " .. text)
        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })
    end,
}, "QuickSay")

-- listen for nearby players chatting
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
                ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })

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

                                -- keep memory from getting too big
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

                            ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })
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
                            ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })

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
                                        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })
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
                Title = "Status",
                Text = "Auto: " .. (Settings.AutoRespond and "ON" or "OFF") .. " | Radius: " .. Settings.ProximityRadius .. " studs | Nearby: " .. nearby .. " | Blacklisted: " .. bl,
            })
        end)
    end
end)

setupProximityListener()

-- ========================================
-- TAB 3: SETTINGS
-- ========================================
local SettingsTab = Window:CreateTab({
    Name = "Settings",
    Icon = "settings",
    ImageSource = "Material",
    ShowTitle = true,
})

SettingsTab:CreateSection("Connection")

SettingsTab:CreateInput({
    Name = "Ollama URL",
    Description = "where ollama is running",
    PlaceholderText = "http://localhost:11434",
    CurrentValue = Settings.OllamaURL,
    Numeric = false,
    MaxCharacters = 200,
    Enter = false,
    Callback = function(text) Settings.OllamaURL = text end,
}, "OllamaURL")

SettingsTab:CreateButton({
    Name = "Test Connection",
    Description = "check if ollama is reachable",
    Callback = function()
        testOllama(function(ok, msg)
            if ok then
                Luna:Notification({ Title = "nice", Content = "ollama is running at " .. Settings.OllamaURL })
            else
                Luna:Notification({ Title = "nope", Content = "cant reach ollama: " .. (msg or "idk why") })
            end
        end)
    end,
})

local ModelDropdown = SettingsTab:CreateDropdown({
    Name = "Model",
    Description = "which model to use",
    Options = { "Loading..." },
    CurrentOption = { Settings.Model },
    MultipleOptions = false,
    Callback = function(option) Settings.Model = type(option) == "table" and option[1] or option end,
}, "Model")

SettingsTab:CreateButton({
    Name = "Refresh Models",
    Callback = function()
        listModels(function(models, err)
            if #models > 0 then
                ModelDropdown:Set({ Options = models, CurrentOption = { models[1] } })
                Settings.Model = models[1]
                Luna:Notification({ Title = "ok", Content = #models .. " model(s) found" })
            else
                Luna:Notification({ Title = "oops", Content = err or "none found. is ollama running?" })
            end
        end)
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Generation")

SettingsTab:CreateSlider({
    Name = "Temperature",
    Range = { 0, 2 },
    Increment = 0.1,
    CurrentValue = Settings.Temperature,
    Callback = function(value) Settings.Temperature = value end,
}, "Temperature")

SettingsTab:CreateSlider({
    Name = "Memory Length",
    Range = { 5, 100 },
    Increment = 5,
    CurrentValue = Settings.MaxMemory,
    Callback = function(value) Settings.MaxMemory = value end,
}, "MaxMemory")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Display")

SettingsTab:CreateToggle({
    Name = "Streaming Responses",
    Description = "word by word (might not work on all executors)",
    CurrentValue = Settings.Streaming,
    Callback = function(value) Settings.Streaming = value end,
}, "Streaming")

SettingsTab:CreateToggle({
    Name = "Typing Animation",
    Description = "show typing dots while waiting",
    CurrentValue = Settings.TypingAnimation,
    Callback = function(value) Settings.TypingAnimation = value end,
}, "TypingAnim")

SettingsTab:CreateToggle({
    Name = "Auto-Scroll",
    CurrentValue = Settings.AutoScroll,
    Callback = function(value) Settings.AutoScroll = value end,
}, "AutoScroll")

SettingsTab:CreateToggle({
    Name = "Sound Effects",
    CurrentValue = Settings.SoundEffects,
    Callback = function(value) Settings.SoundEffects = value end,
}, "SoundFX")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Proximity Chat")

SettingsTab:CreateToggle({
    Name = "Auto-Respond",
    Description = "AI responds to nearby players",
    CurrentValue = Settings.AutoRespond,
    Callback = function(value)
        Settings.AutoRespond = value
        Luna:Notification({ Title = "Auto-Respond", Content = value and "on" or "off" })
    end,
}, "AutoRespond")

SettingsTab:CreateSlider({
    Name = "Proximity Radius",
    Description = "how close players need to be (studs) - slider",
    Range = { 5, 500 },
    Increment = 1,
    CurrentValue = Settings.ProximityRadius,
    Callback = function(value) Settings.ProximityRadius = value end,
}, "ProximityRadius")

SettingsTab:CreateInput({
    Name = "Exact Radius",
    Description = "type exact radius (1-999)",
    PlaceholderText = tostring(Settings.ProximityRadius),
    CurrentValue = "",
    Numeric = true,
    MaxCharacters = 4,
    Enter = false,
    Callback = function(text)
        local num = tonumber(text)
        if num and num >= 1 and num <= 999 then
            Settings.ProximityRadius = num
            Luna:Notification({ Title = "ok", Content = "radius: " .. num .. " studs" })
        else
            Luna:Notification({ Title = "bad", Content = "enter 1-999" })
        end
    end,
}, "ExactRadius")

SettingsTab:CreateSlider({
    Name = "Response Delay",
    Description = "seconds before AI replies (feels more natural)",
    Range = { 0, 5 },
    Increment = 0.5,
    CurrentValue = Settings.ResponseDelay,
    Callback = function(value) Settings.ResponseDelay = value end,
}, "ResponseDelay")

SettingsTab:CreateInput({
    Name = "Chat Prefix",
    Description = "prefix for AI messages in chat",
    PlaceholderText = "[AI]",
    CurrentValue = Settings.ProximityPrefix,
    Numeric = false,
    MaxCharacters = 20,
    Enter = false,
    Callback = function(text) Settings.ProximityPrefix = text end,
}, "ProxPrefix")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Player Blacklist")

local BlacklistParagraph = SettingsTab:CreateParagraph({
    Title = "Blacklisted Players",
    Text = "none",
})

local BlacklistDropdown = SettingsTab:CreateDropdown({
    Name = "Add to Blacklist",
    Description = "AI wont respond to these players",
    Options = {},
    SpecialType = "Player",
    MultipleOptions = false,
    Callback = function(option)
        local name = type(option) == "table" and option[1] or option
        local plr = Players:FindFirstChild(name)
        if plr then
            Settings.IgnoredPlayers[plr.UserId] = true
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Title = "Blacklisted (" .. #list .. ")",
                Text = #list > 0 and table.concat(list, ", ") or "none",
            })
            Luna:Notification({ Title = "blocked", Content = plr.Name .. " added to blacklist" })
        end
    end,
}, "BlacklistPlayer")

SettingsTab:CreateDropdown({
    Name = "Remove from Blacklist",
    Description = "unblock someone",
    Options = {},
    SpecialType = "Player",
    MultipleOptions = false,
    Callback = function(option)
        local name = type(option) == "table" and option[1] or option
        local plr = Players:FindFirstChild(name)
        if plr and Settings.IgnoredPlayers[plr.UserId] then
            Settings.IgnoredPlayers[plr.UserId] = nil
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Title = "Blacklisted (" .. #list .. ")",
                Text = #list > 0 and table.concat(list, ", ") or "none",
            })
            Luna:Notification({ Title = "unblocked", Content = plr.Name .. " removed" })
        end
    end,
}, "UnblockPlayer")

SettingsTab:CreateButton({
    Name = "Refresh Player List",
    Description = "update dropdown with current players",
    Callback = function()
        local names = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then table.insert(names, p.Name) end
        end
        BlacklistDropdown:Set({ Options = names, CurrentOption = { names[1] or "" } })
        Luna:Notification({ Title = "ok", Content = #names .. " players" })
    end,
})

SettingsTab:CreateButton({
    Name = "Clear Blacklist",
    Callback = function()
        Settings.IgnoredPlayers = {}
        BlacklistParagraph:Set({ Title = "Blacklisted Players", Text = "none" })
        Luna:Notification({ Title = "cleared", Content = "everyone unblocked" })
    end,
})

SettingsTab:CreateButton({
    Name = "Blacklist Everyone",
    Description = "block everyone in the server",
    Callback = function()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then Settings.IgnoredPlayers[p.UserId] = true end
        end
        local count = 0
        for _ in pairs(Settings.IgnoredPlayers) do count = count + 1 end
        BlacklistParagraph:Set({
            Title = "Blacklisted (" .. count .. ")",
            Text = count .. " players blocked",
        })
        Luna:Notification({ Title = "done", Content = count .. " players blocked" })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Roleplay Preset")

local PresetNames = {}
for name, _ in pairs(Presets) do table.insert(PresetNames, name) end
table.sort(PresetNames)

SettingsTab:CreateDropdown({
    Name = "AI Personality",
    Options = PresetNames,
    CurrentOption = { CurrentPreset },
    MultipleOptions = false,
    Callback = function(option)
        CurrentPreset = type(option) == "table" and option[1] or option
        UseCustomPrompt = false
        Luna:Notification({ Title = "switched", Content = "now using: " .. CurrentPreset })
    end,
}, "Preset")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Custom Prompt")

SettingsTab:CreateInput({
    Name = "Custom System Prompt",
    Description = "write your own prompt to override the preset",
    PlaceholderText = "type here...",
    CurrentValue = CustomPrompt,
    Numeric = false,
    MaxCharacters = 2000,
    Enter = false,
    Callback = function(text) CustomPrompt = text end,
}, "CustomPrompt")

SettingsTab:CreateButton({
    Name = "Apply Custom Prompt",
    Callback = function()
        if CustomPrompt ~= "" then
            UseCustomPrompt = true
            Luna:Notification({ Title = "applied", Content = "using your custom prompt" })
        else
            Luna:Notification({ Title = "empty", Content = "write something first" })
        end
    end,
})

SettingsTab:CreateButton({
    Name = "Reset to Preset",
    Callback = function()
        UseCustomPrompt = false
        Luna:Notification({ Title = "reset", Content = "back to: " .. CurrentPreset })
    end,
})

SettingsTab:CreateButton({
    Name = "View Current Prompt",
    Callback = function()
        local prompt = getSystemPrompt()
        Luna:Notification({ Title = "prompt", Content = prompt:sub(1, 200) .. (#prompt > 200 and "..." or "") })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Server")

SettingsTab:CreateButton({
    Name = "Rejoin",
    Callback = function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end,
})

SettingsTab:CreateButton({
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
            Luna:Notification({ Title = "nope", Content = "no other servers found" })
        end)
    end,
})

SettingsTab:CreateButton({
    Name = "Copy Job ID",
    Callback = function()
        if setclipboard then
            setclipboard(game.JobId)
        elseif syn and syn.write_clipboard then
            syn.write_clipboard(game.JobId)
        end
        Luna:Notification({ Title = "copied", Content = game.JobId })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Danger Zone")

SettingsTab:CreateButton({
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
        PrivateMessagesParagraph:Set({ Title = "Chat", Text = "wiped." })
        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = "wiped." })
        BlacklistParagraph:Set({ Title = "Blacklisted Players", Text = "none" })
        Luna:Notification({ Title = "gone", Content = "everything reset" })
    end,
})

SettingsTab:CreateButton({
    Name = "Destroy UI",
    Description = "close this thing",
    Callback = function() Luna:Destroy() end,
})

-- load models on startup
task.spawn(function()
    listModels(function(models, err)
        if #models > 0 then
            ModelDropdown:Set({ Options = models, CurrentOption = { models[1] } })
            Settings.Model = models[1]
        else
            warn("[Ollama] couldnt load models: " .. (err or "idk"))
        end
    end)
end)

Luna:LoadAutoloadConfig()
Luna:Notification({ Title = "Ollama AI", Content = "ready - " .. Settings.OllamaURL .. " | " .. Settings.Model })
