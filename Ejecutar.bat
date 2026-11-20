@echo off
rem Ejecuta la interfaz grafica sin compilar. El script se auto-eleva como administrador.
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0src\SoporteTecnico.ps1"
