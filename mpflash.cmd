@echo off
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" mpflash.py
    exit /b
)
uv run --offline mpflash.py
if errorlevel 1 (
    echo.
    echo If Python or dependencies are missing, connect to the internet and run: uv sync
    pause
    exit /b 1
)
