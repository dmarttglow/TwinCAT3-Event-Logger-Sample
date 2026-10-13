@echo off
rem Runs Add-EventFramework.ps1 without changing the PowerShell execution policy.
rem Usage: Add-EventFramework.cmd "D:\Projects\Machine\Machine.sln" ["D:\Folder\With\Files"] [-PlcProject Name] [-Version 1.0.0.1] [-WhatIf]
rem Double-clicked without arguments, it asks for the project path.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-EventFramework.ps1" %*
if "%~1"=="" pause
