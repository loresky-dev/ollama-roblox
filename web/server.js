const express = require('express');
const path = require('path');
const { exec } = require('child_process');

const app = express();
const PORT = 3333;
const OLLAMA_HOST = 'http://127.0.0.1:11434';

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ollama Web</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: #1a1a2e; color: #e0e0e0; height: 100vh; display: flex; flex-direction: column; }
  header { background: #16213e; padding: 12px 24px; display: flex; align-items: center; gap: 16px; border-bottom: 1px solid #0f3460; }
  header h1 { font-size: 18px; font-weight: 600; color: #e94560; }
  #model-select { background: #0f3460; color: #e0e0e0; border: 1px solid #533483; padding: 8px 12px; border-radius: 8px; font-size: 14px; min-width: 220px; cursor: pointer; }
  #model-select:focus { outline: none; border-color: #e94560; }
  .status { font-size: 12px; color: #aaa; margin-left: auto; }
  .status.connected { color: #4ecca3; }
  .status.error { color: #e94560; }
  #chat { flex: 1; overflow-y: auto; padding: 24px; display: flex; flex-direction: column; gap: 16px; }
  .msg { max-width: 800px; width: 100%; margin: 0 auto; padding: 16px 20px; border-radius: 12px; line-height: 1.6; font-size: 15px; }
  .msg.user { background: #0f3460; border-left: 3px solid #e94560; }
  .msg.assistant { background: #16213e; border-left: 3px solid #4ecca3; }
  .msg pre { background: #0d1117; padding: 12px; border-radius: 6px; overflow-x: auto; margin: 8px 0; font-size: 13px; }
  .msg code { font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: 13px; }
  .msg p { margin-bottom: 8px; }
  .msg p:last-child { margin-bottom: 0; }
  #welcome { flex: 1; display: flex; align-items: center; justify-content: center; color: #533483; font-size: 20px; text-align: center; }
  #input-area { padding: 16px 24px; background: #16213e; border-top: 1px solid #0f3460; }
  #input-wrap { max-width: 800px; margin: 0 auto; display: flex; gap: 12px; }
  #user-input { flex: 1; background: #0f3460; color: #e0e0e0; border: 1px solid #533483; padding: 12px 16px; border-radius: 10px; font-size: 15px; font-family: inherit; resize: none; min-height: 44px; max-height: 160px; }
  #user-input:focus { outline: none; border-color: #e94560; }
  #send-btn { background: #e94560; color: white; border: none; padding: 12px 24px; border-radius: 10px; font-size: 15px; font-weight: 600; cursor: pointer; transition: background 0.2s; }
  #send-btn:hover { background: #c73652; }
  #send-btn:disabled { background: #533483; cursor: not-allowed; }
  #stop-btn { background: #533483; color: white; border: none; padding: 12px 24px; border-radius: 10px; font-size: 15px; font-weight: 600; cursor: pointer; display: none; }
  #stop-btn:hover { background: #6a42a0; }
  .thinking { display: inline-block; width: 8px; height: 8px; background: #4ecca3; border-radius: 50%; animation: pulse 1s infinite; }
  @keyframes pulse { 0%, 100% { opacity: 0.3; } 50% { opacity: 1; } }
</style>
</head>
<body>
<header>
  <h1>Ollama Web</h1>
  <select id="model-select"><option disabled selected>Loading models...</option></select>
  <span id="status" class="status">Connecting...</span>
</header>
<div id="chat"><div id="welcome">Pick a model and start chatting</div></div>
<div id="input-area">
  <div id="input-wrap">
    <textarea id="user-input" rows="1" placeholder="Type a message..." autofocus></textarea>
    <button id="send-btn">Send</button>
    <button id="stop-btn">Stop</button>
  </div>
</div>
<script>
const chat=document.getElementById('chat'),welcome=document.getElementById('welcome'),input=document.getElementById('user-input'),sendBtn=document.getElementById('send-btn'),stopBtn=document.getElementById('stop-btn'),modelSelect=document.getElementById('model-select'),status=document.getElementById('status');
let messages=[],controller=null;
async function loadModels(){try{const r=await fetch('/api/models'),d=await r.json();if(d.error)throw new Error(d.error);modelSelect.innerHTML='';d.models.forEach(m=>{const o=document.createElement('option');o.value=m.name;o.textContent=m.name+' ('+(m.size/1e9).toFixed(1)+'GB)';modelSelect.appendChild(o)});status.textContent='Connected';status.className='status connected'}catch(e){status.textContent='Ollama not running';status.className='status error'}}
function addMessage(role,content){if(welcome)welcome.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=content;chat.appendChild(d);chat.scrollTop=chat.scrollHeight;return d}
function renderMarkdown(t){return t.replace(/\`\`\`(\\w*)\\n([\\s\\S]*?)\`\`\`/g,'<pre><code>$2</code></pre>').replace(/\`([^\`]+)\`/g,'<code>$1</code>').replace(/\\*\\*(.+?)\\*\\*/g,'<strong>$1</strong>').replace(/\\n/g,'<br>')}
async function sendMessage(){const text=input.value.trim();if(!text||!modelSelect.value)return;input.value='';input.style.height='auto';messages.push({role:'user',content:text});addMessage('user',renderMarkdown(text.replace(/\\n/g,'<br>')));sendBtn.style.display='none';stopBtn.style.display='inline-block';const ad=addMessage('assistant','<span class="thinking"></span>');let ft='';controller=new AbortController();try{const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model:modelSelect.value,messages}),signal:controller.signal});const reader=r.body.getReader(),dec=new TextDecoder();while(true){const{done,value}=await reader.read();if(done)break;const chunk=dec.decode(value,{stream:true});const lines=chunk.split('\\n').filter(l=>l.startsWith('data: '));for(const line of lines){const j=line.slice(6);if(j==='[DONE]')continue;try{const p=JSON.parse(j);if(p.error){ft+='\\nError: '+p.error;break}if(p.message&&p.message.content){ft+=p.message.content;ad.innerHTML=renderMarkdown(ft);chat.scrollTop=chat.scrollHeight}}catch{}}}messages.push({role:'assistant',content:ft})}catch(e){if(e.name!=='AbortError')ad.innerHTML=renderMarkdown(ft||'Error: '+e.message)}sendBtn.style.display='inline-block';stopBtn.style.display='none'}
stopBtn.addEventListener('click',()=>{if(controller)controller.abort()});
sendBtn.addEventListener('click',sendMessage);
input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMessage()}});
input.addEventListener('input',()=>{input.style.height='auto';input.style.height=Math.min(input.scrollHeight,160)+'px'});
loadModels();
</script>
</body>
</html>`;

app.use(express.json());

app.get('/', (req, res) => res.type('html').send(HTML));

app.get('/api/models', async (req, res) => {
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/tags`);
    const data = await response.json();
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: 'Cannot connect to Ollama. Make sure it is running.' });
  }
});

app.post('/api/chat', async (req, res) => {
  const { model, messages } = req.body;
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: true }),
    });
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      const lines = chunk.split('\n').filter(l => l.trim());
      for (const line of lines) {
        res.write(`data: ${line}\n\n`);
      }
    }
    res.write('data: [DONE]\n\n');
    res.end();
  } catch (e) {
    res.write(`data: ${JSON.stringify({ error: e.message })}\n\n`);
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`Ollama Web UI running at http://localhost:${PORT}`);
});
