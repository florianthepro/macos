@echo off
setlocal
rem Prueft Geraet + vorbereiteten USB-Stick und schreibt einen Report auf den Desktop,
rem um gegenzupruefen, ob setup.exe den Stick korrekt erstellt hat. Kein Admin noetig.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0debug_test-usb.ps1"

echo.
pause
