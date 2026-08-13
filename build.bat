@echo off
setlocal
rem Baut die setup.exe lokal. Ruft src\build.ps1 mit umgangener Ausfuehrungsrichtlinie
rem auf; das PowerShell-Skript laedt die EFI-Nutzdaten und findet/installiert das .NET-8-SDK.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\build.ps1" %*
if errorlevel 1 (
    echo.
    echo Build fehlgeschlagen - Meldungen oben pruefen.
    pause
    exit /b 1
)

echo.
echo Fertig. setup.exe liegt unter:
echo   "%~dp0publish\setup.exe"
echo Diese Datei kannst du jetzt manuell hochladen.
pause
