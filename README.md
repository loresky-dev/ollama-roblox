# ollama roblox

run a local AI in any roblox game. no cloud APIs, no api keys, no monthly subscriptions. just ollama running on your pc and a script in your executor.

has two modes:
- **private chat** - talk to the AI privately, nobody else sees it
- **proximity chat** - AI auto-replies to nearby players in game chat

also comes with a web UI for chatting with ollama in your browser (in the `web/` folder).

---

## what you need

1. [Ollama](https://ollama.com/download) installed and running
2. at least one model pulled:
   ```
   ollama pull qwen2.5:7b
   ```
3. a roblox executor that supports HTTP requests (synapse, krnl, fluxus, wave, etc.)

---

## setup

1. start ollama (open the app or run `ollama serve`)
2. copy the contents of `ollama-roblox.lua` into your executor
3. run it in any game. the luna UI pops up with 3 tabs.

---

## how to use

### private chat

open the Private Chat tab, type something, press enter. the AI responds privately. nobody else sees it. use Export Chat to copy everything.

### proximity chat

open the Proximity Chat tab. make sure Auto-Respond is ON in Settings. when someone near you types in chat, the AI replies automatically in game chat. it keeps context of the conversation too.

### player blacklist

go to Settings -> Player Blacklist. use the dropdown to add players. the AI ignores them completely. hit Refresh Player List when players join/leave. Blacklist All blocks everyone at once.

### radius

in Settings -> Proximity Chat, there's a slider (5-500 studs) and an exact input field (1-999). the status bar shows your current radius and how many players are nearby.

### presets

Settings -> Roleplay Preset has 15 personalities: Pirate Captain, Medieval Knight, Wizard, Detective, Comedian, etc. or write your own Custom Prompt.

---

## settings

| setting | default | what it does |
|---------|---------|-------------|
| Ollama URL | `http://localhost:11434` | where ollama is running |
| Model | `qwen2.5:7b` | which model to use |
| Temperature | 0.7 | creativity (0 = boring, 2 = unhinged) |
| Memory Length | 50 | how many messages to remember |
| Proximity Radius | 50 studs | detection range |
| Response Delay | 1.5s | delay before AI replies (feels more natural) |
| Chat Prefix | `[AI]` | prefix for AI messages in game chat |
| Auto-Respond | ON | toggle proximity responses |
| Typing Animation | ON | typing dots while waiting |

---

## web UI

there's also a simple web UI in the `web/` folder. it's a dark-themed chat interface for ollama that runs in your browser.

### to run it:

```
cd web
npm install
```

make sure ollama is running, then:

```
npm start
```

or just double-click `Ollama Web.bat` on windows.

open http://localhost:3333 in your browser.

### what it does

- dark cyberpunk theme
- model picker with size display
- streaming responses
- markdown rendering (code blocks, bold, inline code)
- stop generation button
- single file server, no build step needed

### changing the port

edit the top of `web/server.js`:

```js
const PORT = 3333;  // change this
```

---

## executor compatibility

| executor | HTTP function | works? |
|----------|--------------|--------|
| Synapse X | `syn.request` | yes |
| KRNL | `http_request` | yes |
| Wave | `request` | yes |
| Fluxus | `fluxus.request` | yes |
| Script-Ware | `http_request` | yes |
| Delta | `http_request` | yes |

the script auto-detects which one to use.

---

## troubleshooting

| problem | fix |
|---------|-----|
| "ur executor doesnt support http" | your executor doesnt support HTTP. try a different one. |
| "cant reach ollama" | make sure ollama is running (`ollama serve` or open the app) |
| AI doesnt reply to nearby players | check Auto-Respond is ON, radius is big enough, player isnt blacklisted |
| luna UI doesnt load | your executor might not support loadstring |
| responses are slow | bigger models = slower. try `qwen2.5:3b` |

---

## editing defaults

at the top of `ollama-roblox.lua`:

```lua
local Settings = {
    Model = "qwen2.5:7b",
    Temperature = 0.7,
    ProximityRadius = 50,
    ResponseDelay = 1.5,
    ProximityPrefix = "[AI]",
    AutoRespond = true,
}
```

---

## license

MIT
