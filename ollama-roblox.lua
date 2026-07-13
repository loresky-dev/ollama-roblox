--[[
    Ollama AI Chat for Roblox
    Works on any executor (Synapse X, KRNL, Wave, Fluxus, etc.)
    Uses Luna Interface Suite UI
    Requires: Ollama running locally on localhost:11434
]]

--// Services
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

--// HTTP (cross-executor compatibility)
local http_request = http_request or request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)

if not http_request then
    warn("[Ollama AI] Your executor does not support HTTP requests!")
    return
end

--// Luna
local Luna = loadstring(game:HttpGet("https://raw.nebulasoftworks.xyz/luna", true))()

--// Config
local OLLAMA_URL = "http://localhost:11434"

--// State
local PrivateMessages = {}
local ProximityMessages = {}
local ProximityMemory = {}
local CurrentPreset = "Friendly Assistant"
local CustomPrompt = ""
local UseCustomPrompt = false
local isProcessing = false

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

--// Roleplay Presets
local Presets = {
    ["Friendly Assistant"] = "You are a friendly, helpful AI assistant in Roblox. Be concise, warm, and helpful. Keep responses short for chat.",
    ["Roblox Guide"] = "You are a Roblox expert guide. Help players with tips, tricks, game recommendations, and Roblox knowledge. Be enthusiastic and knowledgeable.",
    ["Storyteller"] = "You are a master storyteller. Narrate events dramatically, describe scenes vividly, and respond to what players say in-character as a narrator.",
    ["Fantasy NPC"] = "You are a fantasy NPC in a medieval world. Speak in a rustic, humble tone. Use words like 'traveler', 'adventurer', 'aye', 'good sir'.",
    ["Medieval Knight"] = "You are a noble knight of the realm. Speak formally and honorably. Use 'thy', 'thou', 'forsooth', 'huzzah'. Defend the innocent!",
    ["Pirate Captain"] = "You are a swashbuckling pirate captain! Say 'arr', 'matey', 'ye', 'shiver me timbers'. Tell tales of the sea and treasure.",
    ["Sci-Fi Android"] = "You are a futuristic android. Speak precisely, reference circuits, data, and logic. Occasionally glitch. Use technical jargon.",
    ["Detective"] = "You are a sharp-witted detective. Analyze everything, ask probing questions, say 'Elementary', 'fascinating', 'case closed'.",
    ["Wizard"] = "You are an ancient wizard. Say 'ah yes', 'by the stars', 'hmm interesting'. Reference magic, spells, the arcane. Be wise and cryptic.",
    ["Merchant"] = "You are a traveling merchant. Always try to 'sell' things. Say 'ah, a customer!', 'I have just the thing', 'wonderful choice'.",
    ["Villager"] = "You are a simple villager. Say 'hmm', 'oh dear', 'the weather is nice'. Talk about crops, trades, and village gossip.",
    ["Survival Companion"] = "You are a survival companion. Help players survive. Warn about dangers, suggest resources, stay alert. Short and urgent messages.",
    ["Dungeon Master"] = "You are a dungeon master narrating a tabletop RPG. Describe rooms, roll imaginary dice, create encounters, respond to player actions.",
    ["Horror Character"] = "You are a mysterious, eerie character. Speak in unsettling whispers. Reference darkness, shadows, things unseen. Create tension.",
    ["Comedian"] = "You are a stand-up comedian in Roblox. Tell jokes, be witty, make puns, roast players (lightly). Keep it fun and family-friendly.",
}

--// Util: Safe HTTP request (handles all executor formats)
local function makeRequest(url, method, body)
    localrequestData = {
        Url = url,
        Method = method or "GET",
        Headers = { ["Content-Type"] = "application/json" },
    }
    if body then
        requestData.Body = body
    end

    local success, result = pcall(function()
        return http_request(requestData)
    end)

    if not success then
        return nil, "HTTP request failed: " .. tostring(result)
    end

    -- Extract body and status (handle all executor formats)
    local responseBody = result.Body or result.body or result.ResponseBody or result.responseBody or ""
    local statusCode = result.StatusCode or result.statusCode or result.Status or result.status or 0

    return { Body = responseBody, StatusCode = statusCode }
end

--// Util: Ollama API Call (NON-STREAMING, reliable for executors)
local function ollamaChat(messages, callback)
    local url = Settings.OllamaURL

    local payload = HttpService:JSONEncode({
        model = Settings.Model,
        messages = messages,
        stream = false,
        options = {
            temperature = Settings.Temperature,
        },
    })

    task.spawn(function()
        local res, err = makeRequest(url .. "/api/chat", "POST", payload)

        if not res then
            callback("[Error: " .. (err or "unknown") .. "]", true)
            return
        end

        if res.StatusCode == 200 then
            local ok, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
            if ok and parsed.message and parsed.message.content then
                callback(parsed.message.content, true)
            else
                callback("[Error: Bad response from Ollama]", true)
            end
        else
            callback("[Error: HTTP " .. tostring(res.StatusCode) .. "]", true)
        end
    end)
end

--// Util: Test Ollama connection
local function testOllama(callback)
    task.spawn(function()
        local res, err = makeRequest(Settings.OllamaURL .. "/api/tags", "GET")
        if not res then
            callback(false, err or "Connection failed")
            return
        end
        if res.StatusCode == 200 then
            callback(true, "Connected!")
        else
            callback(false, "HTTP " .. tostring(res.StatusCode))
        end
    end)
end

local function listModels(callback)
    task.spawn(function()
        local res, err = makeRequest(Settings.OllamaURL .. "/api/tags", "GET")

        if not res then
            callback({}, err or "Connection failed")
            return
        end

        if res.StatusCode == 200 then
            local ok, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
            if ok and parsed.models then
                local names = {}
                for _, m in ipairs(parsed.models) do
                    table.insert(names, m.name)
                end
                callback(names, nil)
            else
                callback({}, "Failed to parse response")
            end
        else
            callback({}, "HTTP " .. tostring(res.StatusCode))
        end
    end)
end

--// Util: Build context from message history
local function buildContext(messages, maxLen)
    local trimmed = {}
    local start = math.max(1, #messages - maxLen + 1)
    for i = start, #messages do
        table.insert(trimmed, messages[i])
    end
    return trimmed
end

--// Util: Get current system prompt
local function getSystemPrompt()
    if UseCustomPrompt and CustomPrompt ~= "" then
        return CustomPrompt
    end
    return Presets[CurrentPreset] or Presets["Friendly Assistant"]
end

--// Util: Get distance between two positions
local function getDistance(pos1, pos2)
    return (pos1 - pos2).Magnitude
end

--// Util: Get player from message (safe for all executor types)
local function getPlayerFromMessage(message)
    pcall(function()
        local textSource = message.TextSource
        if textSource then
            local userId = textSource.UserId
            if userId and userId > 0 then
                local player = Players:GetPlayerByUserId(userId)
                if player then
                    return player
                end
            end
        end
    end)
    return nil
end

--// Util: Check if player is within radius
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

--// Util: Check if player is ignored
local function isPlayerIgnored(player)
    return Settings.IgnoredPlayers[player.UserId] == true
end

--// Util: Send via TextChatService (proximity)
local function sendProximityChat(text)
    -- Try modern TextChatService
    local ok1 = pcall(function()
        local channels = TextChatService:FindFirstChild("TextChannels")
        if channels then
            local general = channels:FindFirstChild("RBXGeneral")
            if general then
                general:SendAsync(text)
                return true
            end
        end
    end)
    if ok1 then return end

    -- Fallback: legacy chat
    pcall(function()
        local events = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
        if events then
            local sayEvent = events:FindFirstChild("SayMessageRequest")
            if sayEvent then
                sayEvent:FireServer(text, "All")
            end
        end
    end)
end

--// Util: Typing animation
local function typingAnimation(paragraph, baseText, duration)
    local dots = {"", ".", "..", "..."}
    local i = 1
    local elapsed = 0
    local alive = true
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not alive then return end
        elapsed = elapsed + dt
        if elapsed >= duration then
            alive = false
            conn:Disconnect()
            return
        end
        i = (i % #dots) + 1
        pcall(function()
            paragraph:Set({ Title = baseText, Text = "Typing" .. dots[i] })
        end)
    end)
    return {
        Disconnect = function()
            alive = false
            if conn and conn.Connected then conn:Disconnect() end
        end
    }
end

--// Util: Format proximity display
local function formatProximityDisplay()
    if #ProximityMessages == 0 then
        return "Waiting for nearby players to chat..."
    end
    local displayText = table.concat(ProximityMessages, "\n")
    local lines = {}
    for line in displayText:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    if #lines > 30 then
        local trimmed = {}
        for i = #lines - 29, #lines do
            table.insert(trimmed, lines[i])
        end
        displayText = table.concat(trimmed, "\n")
    end
    return displayText
end

--// Util: Format private display
local function formatPrivateDisplay()
    if #PrivateMessages == 0 then
        return "No messages yet. Type below to start chatting!"
    end
    local parts = {}
    for _, msg in ipairs(PrivateMessages) do
        if msg.role == "user" then
            table.insert(parts, "[You]: " .. msg.content)
        else
            table.insert(parts, "[AI]: " .. msg.content)
        end
    end
    local displayText = table.concat(parts, "\n")
    local lines = {}
    for line in displayText:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    if #lines > 40 then
        local trimmed = {}
        for i = #lines - 39, #lines do
            table.insert(trimmed, lines[i])
        end
        displayText = table.concat(trimmed, "\n")
    end
    return displayText
end

--// ============================================
--// UI
--// ============================================
local Window = Luna:CreateWindow({
    Name = "Ollama AI",
    Subtitle = "Local AI for Roblox",
    LogoID = nil,
    LoadingEnabled = true,
    LoadingTitle = "Ollama AI",
    LoadingSubtitle = "Connecting to local AI...",
    ConfigSettings = {
        RootFolder = nil,
        ConfigFolder = "OllamaAI",
    },
    KeySystem = false,
})

--// ============================================
--// TAB 1: PRIVATE CHAT
--// ============================================
local PrivateTab = Window:CreateTab({
    Name = "Private Chat",
    Icon = "chat",
    ImageSource = "Material",
    ShowTitle = true,
})

PrivateTab:CreateSection("Private AI Conversation")
PrivateTab:CreateParagraph({
    Title = "Private Chat",
    Text = "Messages are only visible to you. The AI responds privately. Press Enter to send.",
})

PrivateTab:CreateDivider()

local PrivateMessagesParagraph = PrivateTab:CreateParagraph({
    Title = "Chat",
    Text = "No messages yet. Type below to start chatting!",
})

PrivateTab:CreateDivider()

local PrivateInput = PrivateTab:CreateInput({
    Name = "Message",
    PlaceholderText = "Type your message...",
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
            typing = typingAnimation(PrivateMessagesParagraph, "Chat", 60)
        end

        local apiMessages = {
            { role = "system", content = getSystemPrompt() },
        }
        local context = buildContext(PrivateMessages, Settings.MaxMemory)
        for _, msg in ipairs(context) do
            table.insert(apiMessages, { role = msg.role, content = msg.content })
        end

        ollamaChat(apiMessages, function(response, done)
            if done then
                if typing then typing:Disconnect() end

                if response:match("^%[Error") then
                    table.insert(PrivateMessages, { role = "assistant", content = response })
                else
                    table.insert(PrivateMessages, { role = "assistant", content = response })
                end
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

--// ============================================
--// TAB 2: PROXIMITY CHAT
--// ============================================
local ProximityTab = Window:CreateTab({
    Name = "Proximity Chat",
    Icon = "record_voice_over",
    ImageSource = "Material",
    ShowTitle = true,
})

ProximityTab:CreateSection("Auto AI Responses Near You")
ProximityTab:CreateParagraph({
    Title = "How It Works",
    Text = "When a player near you chats, the AI automatically responds in game chat. Configure radius and delays in Settings.",
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

--// ============================================
--// PROXIMITY CHAT: Listen for nearby messages
--// ============================================
local function setupProximityListener()
    -- Try modern TextChatService
    local success = pcall(function()
        local channels = TextChatService:FindFirstChild("TextChannels")
        if not channels then return false end
        local general = channels:FindFirstChild("RBXGeneral")
        if not general then return false end

        general.MessageReceived:Connect(function(message)
            local ok, err = pcall(function()
                if isProcessing then return end
                if not Settings.AutoRespond then return end

                local senderPlayer = getPlayerFromMessage(message)
                if not senderPlayer then return end
                if senderPlayer == LocalPlayer then return end
                if isPlayerIgnored(senderPlayer) then return end
                if not isPlayerInRadius(senderPlayer) then return end

                local messageText = message.Text
                if not messageText or messageText == "" then return end

                isProcessing = true

                table.insert(ProximityMessages, "[" .. senderPlayer.Name .. "]: " .. messageText)
                ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })

                task.delay(Settings.ResponseDelay, function()
                    local typing = nil
                    if Settings.TypingAnimation then
                        typing = typingAnimation(ProximityMessagesParagraph, "Activity Log", 60)
                    end

                    local apiMessages = {
                        { role = "system", content = getSystemPrompt() .. "\n\nYou are chatting in a Roblox game. A player named " .. senderPlayer.Name .. ' said: "' .. messageText .. '". Respond naturally as if you are a player in the game. Keep it SHORT (under 80 chars). No markdown. No code blocks. Be natural and conversational.' },
                    }
                    local context = buildContext(ProximityMemory, math.min(Settings.MaxMemory, 20))
                    for _, msg in ipairs(context) do
                        table.insert(apiMessages, { role = msg.role, content = msg.content })
                    end
                    table.insert(apiMessages, { role = "user", content = senderPlayer.Name .. ": " .. messageText })

                    ollamaChat(apiMessages, function(response, done)
                        if done then
                            if typing then typing:Disconnect() end

                            if not response:match("^%[Error") then
                                local clean = response:gsub("\n", " "):gsub("%*%*", ""):gsub("`[^`]*`", ""):sub(1, 200)
                                local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. clean) or clean

                                sendProximityChat(chatText)

                                table.insert(ProximityMessages, "[AI -> " .. senderPlayer.Name .. "]: " .. clean)
                                table.insert(ProximityMemory, { role = "user", content = senderPlayer.Name .. ": " .. messageText })
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

                            ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })
                            isProcessing = false
                        end
                    end)
                end)
            end)

            if not ok then
                isProcessing = false
                warn("[Ollama AI] Proximity listener error: " .. tostring(err))
            end
        end)

        return true
    end)

    if not success then
        -- Fallback: try legacy chat
        pcall(function()
            local events = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
            if events then
                local onNewMessage = events:FindFirstChild("OnNewMessage")
                if onNewMessage then
                    onNewMessage.OnClientEvent:Connect(function(channelName, messageData, channelTarget)
                        pcall(function()
                            if isProcessing then return end
                            if not Settings.AutoRespond then return end

                            local senderName = messageData.FromSpeaker
                            if not senderName or senderName == LocalPlayer.Name then return end

                            local senderPlayer = Players:FindFirstChild(senderName)
                            if not senderPlayer then return end
                            if isPlayerIgnored(senderPlayer) then return end
                            if not isPlayerInRadius(senderPlayer) then return end

                            local messageText = messageData.Message
                            if not messageText or messageText == "" then return end

                            isProcessing = true

                            table.insert(ProximityMessages, "[" .. senderName .. "]: " .. messageText)
                            ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = formatProximityDisplay() })

                            task.delay(Settings.ResponseDelay, function()
                                local apiMessages = {
                                    { role = "system", content = getSystemPrompt() .. "\n\nYou are chatting in a Roblox game. A player named " .. senderName .. ' said: "' .. messageText .. '". Respond naturally. Keep it SHORT (under 80 chars). No markdown.' },
                                }
                                local context = buildContext(ProximityMemory, math.min(Settings.MaxMemory, 20))
                                for _, msg in ipairs(context) do
                                    table.insert(apiMessages, { role = msg.role, content = msg.content })
                                end
                                table.insert(apiMessages, { role = "user", content = senderName .. ": " .. messageText })

                                ollamaChat(apiMessages, function(response, done)
                                    if done then
                                        if not response:match("^%[Error") then
                                            local clean = response:gsub("\n", " "):gsub("%*%*", ""):sub(1, 200)
                                            local chatText = Settings.ProximityPrefix ~= "" and (Settings.ProximityPrefix .. " " .. clean) or clean
                                            sendProximityChat(chatText)

                                            table.insert(ProximityMessages, "[AI -> " .. senderName .. "]: " .. clean)
                                            table.insert(ProximityMemory, { role = "user", content = senderName .. ": " .. messageText })
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

--// Update status periodically
task.spawn(function()
    while true do
        task.wait(3)
        pcall(function()
            local nearbyCount = 0
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer and isPlayerInRadius(player) then
                    nearbyCount = nearbyCount + 1
                end
            end
            local blacklistCount = 0
            for _ in pairs(Settings.IgnoredPlayers) do blacklistCount = blacklistCount + 1 end
            ProximityStatusParagraph:Set({
                Title = "Status",
                Text = "Auto-Respond: " .. (Settings.AutoRespond and "ON" or "OFF") .. " | Radius: " .. Settings.ProximityRadius .. " studs | Nearby: " .. nearbyCount .. " | Blacklisted: " .. blacklistCount,
            })
        end)
    end
end)

setupProximityListener()

--// ============================================
--// TAB 3: SETTINGS
--// ============================================
local SettingsTab = Window:CreateTab({
    Name = "Settings",
    Icon = "settings",
    ImageSource = "Material",
    ShowTitle = true,
})

SettingsTab:CreateSection("Connection")

SettingsTab:CreateInput({
    Name = "Ollama URL",
    Description = "URL of your Ollama server",
    PlaceholderText = "http://localhost:11434",
    CurrentValue = Settings.OllamaURL,
    Numeric = false,
    MaxCharacters = 200,
    Enter = false,
    Callback = function(text)
        Settings.OllamaURL = text
    end,
}, "OllamaURL")

SettingsTab:CreateButton({
    Name = "Test Connection",
    Description = "Check if Ollama is reachable",
    Callback = function()
        testOllama(function(ok, msg)
            if ok then
                Luna:Notification({ Title = "Connected", Content = "Ollama is running at " .. Settings.OllamaURL })
            else
                Luna:Notification({ Title = "Failed", Content = "Cannot reach Ollama: " .. (msg or "unknown error") })
            end
        end)
    end,
})

local ModelDropdown = SettingsTab:CreateDropdown({
    Name = "Model",
    Description = "Select the Ollama model to use",
    Options = { "Loading..." },
    CurrentOption = { Settings.Model },
    MultipleOptions = false,
    Callback = function(option)
        Settings.Model = type(option) == "table" and option[1] or option
    end,
}, "Model")

SettingsTab:CreateButton({
    Name = "Refresh Models",
    Callback = function()
        listModels(function(models, err)
            if #models > 0 then
                ModelDropdown:Set({ Options = models, CurrentOption = { models[1] } })
                Settings.Model = models[1]
                Luna:Notification({ Title = "Models Loaded", Content = "Found " .. #models .. " model(s)." })
            else
                Luna:Notification({ Title = "Error", Content = err or "No models found. Is Ollama running?" })
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
    Callback = function(value)
        Settings.Temperature = value
    end,
}, "Temperature")

SettingsTab:CreateSlider({
    Name = "Memory Length",
    Range = { 5, 100 },
    Increment = 5,
    CurrentValue = Settings.MaxMemory,
    Callback = function(value)
        Settings.MaxMemory = value
    end,
}, "MaxMemory")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Display")

SettingsTab:CreateToggle({
    Name = "Streaming Responses",
    Description = "Show responses word by word (may not work on all executors)",
    CurrentValue = Settings.Streaming,
    Callback = function(value)
        Settings.Streaming = value
    end,
}, "Streaming")

SettingsTab:CreateToggle({
    Name = "Typing Animation",
    Description = "Show typing dots while waiting",
    CurrentValue = Settings.TypingAnimation,
    Callback = function(value)
        Settings.TypingAnimation = value
    end,
}, "TypingAnim")

SettingsTab:CreateToggle({
    Name = "Auto-Scroll",
    CurrentValue = Settings.AutoScroll,
    Callback = function(value)
        Settings.AutoScroll = value
    end,
}, "AutoScroll")

SettingsTab:CreateToggle({
    Name = "Sound Effects",
    CurrentValue = Settings.SoundEffects,
    Callback = function(value)
        Settings.SoundEffects = value
    end,
}, "SoundFX")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Proximity Chat")

SettingsTab:CreateToggle({
    Name = "Auto-Respond",
    Description = "AI responds to nearby players automatically",
    CurrentValue = Settings.AutoRespond,
    Callback = function(value)
        Settings.AutoRespond = value
        Luna:Notification({ Title = "Auto-Respond", Content = value and "Enabled" or "Disabled" })
    end,
}, "AutoRespond")

SettingsTab:CreateSlider({
    Name = "Proximity Radius",
    Description = "How close players must be (in studs) - slider",
    Range = { 5, 500 },
    Increment = 1,
    CurrentValue = Settings.ProximityRadius,
    Callback = function(value)
        Settings.ProximityRadius = value
    end,
}, "ProximityRadius")

SettingsTab:CreateInput({
    Name = "Exact Radius",
    Description = "Type an exact radius value (1-999)",
    PlaceholderText = tostring(Settings.ProximityRadius),
    CurrentValue = "",
    Numeric = true,
    MaxCharacters = 4,
    Enter = false,
    Callback = function(text)
        local num = tonumber(text)
        if num and num >= 1 and num <= 999 then
            Settings.ProximityRadius = num
            Luna:Notification({ Title = "Radius Set", Content = "Proximity radius: " .. num .. " studs" })
        else
            Luna:Notification({ Title = "Invalid", Content = "Enter a number between 1 and 999" })
        end
    end,
}, "ExactRadius")

SettingsTab:CreateSlider({
    Name = "Response Delay",
    Description = "Seconds before AI responds (feels more natural)",
    Range = { 0, 5 },
    Increment = 0.5,
    CurrentValue = Settings.ResponseDelay,
    Callback = function(value)
        Settings.ResponseDelay = value
    end,
}, "ResponseDelay")

SettingsTab:CreateInput({
    Name = "Chat Prefix",
    Description = "Prefix for AI messages in game chat",
    PlaceholderText = "[AI]",
    CurrentValue = Settings.ProximityPrefix,
    Numeric = false,
    MaxCharacters = 20,
    Enter = false,
    Callback = function(text)
        Settings.ProximityPrefix = text
    end,
}, "ProxPrefix")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Player Blacklist")

local BlacklistParagraph = SettingsTab:CreateParagraph({
    Title = "Blacklisted Players",
    Text = "None",
})

local BlacklistDropdown = SettingsTab:CreateDropdown({
    Name = "Add Player to Blacklist",
    Description = "AI will NOT respond to blacklisted players",
    Options = {},
    SpecialType = "Player",
    MultipleOptions = false,
    Callback = function(option)
        local playerName = type(option) == "table" and option[1] or option
        local player = Players:FindFirstChild(playerName)
        if player then
            Settings.IgnoredPlayers[player.UserId] = true
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Title = "Blacklisted Players (" .. #list .. ")",
                Text = #list > 0 and table.concat(list, ", ") or "None",
            })
            Luna:Notification({ Title = "Blacklisted", Content = player.Name .. " added to blacklist" })
        end
    end,
}, "BlacklistPlayer")

SettingsTab:CreateDropdown({
    Name = "Remove from Blacklist",
    Description = "Unblock a player",
    Options = {},
    SpecialType = "Player",
    MultipleOptions = false,
    Callback = function(option)
        local playerName = type(option) == "table" and option[1] or option
        local player = Players:FindFirstChild(playerName)
        if player and Settings.IgnoredPlayers[player.UserId] then
            Settings.IgnoredPlayers[player.UserId] = nil
            local list = {}
            for uid, _ in pairs(Settings.IgnoredPlayers) do
                local p = Players:GetPlayerByUserId(uid)
                if p then table.insert(list, p.Name) end
            end
            BlacklistParagraph:Set({
                Title = "Blacklisted Players (" .. #list .. ")",
                Text = #list > 0 and table.concat(list, ", ") or "None",
            })
            Luna:Notification({ Title = "Removed", Content = player.Name .. " removed from blacklist" })
        end
    end,
}, "UnblockPlayer")

SettingsTab:CreateButton({
    Name = "Refresh Player List",
    Description = "Update the dropdown with current players",
    Callback = function()
        local names = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                table.insert(names, p.Name)
            end
        end
        BlacklistDropdown:Set({ Options = names, CurrentOption = { names[1] or "" } })
        Luna:Notification({ Title = "Refreshed", Content = #names .. " players in list" })
    end,
})

SettingsTab:CreateButton({
    Name = "Clear Entire Blacklist",
    Callback = function()
        Settings.IgnoredPlayers = {}
        BlacklistParagraph:Set({ Title = "Blacklisted Players", Text = "None" })
        Luna:Notification({ Title = "Cleared", Content = "All players unblocked." })
    end,
})

SettingsTab:CreateButton({
    Name = "Blacklist All Current Players",
    Description = "Block everyone currently in the server",
    Callback = function()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                Settings.IgnoredPlayers[p.UserId] = true
            end
        end
        local count = 0
        for _ in pairs(Settings.IgnoredPlayers) do count = count + 1 end
        BlacklistParagraph:Set({
            Title = "Blacklisted Players (" .. count .. ")",
            Text = count > 0 and tostring(count) .. " players blacklisted" or "None",
        })
        Luna:Notification({ Title = "All Blacklisted", Content = count .. " players blocked" })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Roleplay Preset")

local PresetNames = {}
for name, _ in pairs(Presets) do
    table.insert(PresetNames, name)
end
table.sort(PresetNames)

SettingsTab:CreateDropdown({
    Name = "AI Personality",
    Options = PresetNames,
    CurrentOption = { CurrentPreset },
    MultipleOptions = false,
    Callback = function(option)
        CurrentPreset = type(option) == "table" and option[1] or option
        UseCustomPrompt = false
        Luna:Notification({ Title = "Preset Changed", Content = "Now using: " .. CurrentPreset })
    end,
}, "Preset")

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Custom Prompt")

SettingsTab:CreateInput({
    Name = "Custom System Prompt",
    Description = "Override the preset with your own prompt",
    PlaceholderText = "Write your custom system prompt here...",
    CurrentValue = CustomPrompt,
    Numeric = false,
    MaxCharacters = 2000,
    Enter = false,
    Callback = function(text)
        CustomPrompt = text
    end,
}, "CustomPrompt")

SettingsTab:CreateButton({
    Name = "Apply Custom Prompt",
    Callback = function()
        if CustomPrompt ~= "" then
            UseCustomPrompt = true
            Luna:Notification({ Title = "Applied", Content = "Using your custom prompt." })
        else
            Luna:Notification({ Title = "Empty", Content = "Write a prompt first." })
        end
    end,
})

SettingsTab:CreateButton({
    Name = "Reset to Preset",
    Callback = function()
        UseCustomPrompt = false
        Luna:Notification({ Title = "Reset", Content = "Using preset: " .. CurrentPreset })
    end,
})

SettingsTab:CreateButton({
    Name = "View Current Prompt",
    Callback = function()
        local prompt = getSystemPrompt()
        Luna:Notification({ Title = "System Prompt", Content = prompt:sub(1, 200) .. (#prompt > 200 and "..." or "") })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Server")

SettingsTab:CreateButton({
    Name = "Rejoin Server",
    Description = "Rejoin the current server",
    Callback = function()
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    end,
})

SettingsTab:CreateButton({
    Name = "Server Hop",
    Description = "Join a different server",
    Callback = function()
        pcall(function()
            local res = makeRequest("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100", "GET")
            if res and res.StatusCode == 200 then
                local data = HttpService:JSONDecode(res.Body)
                if data and data.data then
                    for _, server in ipairs(data.data) do
                        if server.id ~= game.JobId and server.playing < server.maxPlayers then
                            TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
                            return
                        end
                    end
                end
            end
            Luna:Notification({ Title = "Server Hop", Content = "No other servers found." })
        end)
    end,
})

SettingsTab:CreateButton({
    Name = "Copy Job ID",
    Description = "Copy the current server ID",
    Callback = function()
        if setclipboard then
            setclipboard(game.JobId)
        elseif syn and syn.write_clipboard then
            syn.write_clipboard(game.JobId)
        end
        Luna:Notification({ Title = "Copied", Content = "Job ID: " .. game.JobId })
    end,
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Danger Zone")

SettingsTab:CreateButton({
    Name = "Clear ALL Data",
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
        PrivateMessagesParagraph:Set({ Title = "Chat", Text = "All data cleared." })
        ProximityMessagesParagraph:Set({ Title = "Activity Log", Text = "All data cleared." })
        BlacklistParagraph:Set({ Title = "Blacklisted Players", Text = "None" })
        Luna:Notification({ Title = "Wiped", Content = "All data and settings have been reset." })
    end,
})

SettingsTab:CreateButton({
    Name = "Destroy UI",
    Description = "Close the Luna interface",
    Callback = function()
        Luna:Destroy()
    end,
})

--// Load models on startup
task.spawn(function()
    listModels(function(models, err)
        if #models > 0 then
            ModelDropdown:Set({ Options = models, CurrentOption = { models[1] } })
            Settings.Model = models[1]
        else
            warn("[Ollama AI] Could not load models: " .. (err or "unknown"))
        end
    end)
end)

Luna:LoadAutoloadConfig()

Luna:Notification({
    Title = "Ollama AI Ready",
    Content = "URL: " .. Settings.OllamaURL .. " | Model: " .. Settings.Model,
})
