@echo off
rem Ejecuta la version de consola (menu de texto) sin compilar.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\SoporteTecnico.ps1" -Consola
