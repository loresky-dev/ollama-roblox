@echo off
title Ollama Web UI
echo Starting Ollama Web UI...
echo.
echo Make sure Ollama is running (ollama serve or just open Ollama app)
echo.
start "" "http://localhost:3333"
node "%~dp0server.js"
pause
