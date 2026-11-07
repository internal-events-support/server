@echo off
title Restart CasparCG
setlocal
set "START_ALL=%USERPROFILE%\Documents\CasparCG\start-all.bat"

if not exist "%START_ALL%" (
    echo The patched CasparCG is not installed yet.
    echo Run "Build and Install CasparCG.bat" in the "CasparCG Build" folder first.
    echo Nothing has been stopped.
    pause
    exit /b 1
)

echo Stopping client...
taskkill /F /IM casparcg-client.exe >nul 2>&1

echo Stopping server...
powershell -NoProfile -Command "try { $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 5250); $w = New-Object IO.StreamWriter($c.GetStream()); $w.Write(\"KILL`r`n\"); $w.Flush(); Start-Sleep -Milliseconds 300; $c.Close() } catch {}"

set /a TRIES=0
:waitserver
tasklist /FI "IMAGENAME eq casparcg.exe" | find /i "casparcg.exe" >nul
if errorlevel 1 goto serverstopped
set /a TRIES+=1
if %TRIES% geq 10 goto forcestop
timeout /t 1 /nobreak >nul
goto waitserver

:forcestop
taskkill /F /T /IM casparcg.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:serverstopped
echo Stopping scanner...
taskkill /F /IM "casparcg-scanner*" >nul 2>&1
timeout /t 2 /nobreak >nul

echo Starting scanner, server and client...
call "%START_ALL%"
