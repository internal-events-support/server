@echo off
setlocal
set "ROOT=%~dp0"
set "SERVER=%ROOT%Server"
set "CLIENT=%ROOT%Client"

:: At boot, give the network adapters and Dante Virtual Soundcard time to come up
if /i "%~1"=="boot" timeout /t 20 /nobreak >nul

set "SCANNER="
for %%F in ("%SERVER%\casparcg-scanner-*.exe") do set "SCANNER=%%~nxF"
if not defined SCANNER (
    echo Media scanner not found in "%SERVER%"
    pause
    exit /b 1
)

:: The scanner stalls when run from the Server folder, so it runs from its own
:: folder. This needs the full paths set in casparcg.config.
if not exist "%ROOT%Scanner" mkdir "%ROOT%Scanner"
start "CasparCG Scanner" /D "%ROOT%Scanner" "%SERVER%\%SCANNER%" --caspar.config="%SERVER%\casparcg.config" --paths.ffmpeg="%SERVER%\ffmpeg.exe" --paths.ffprobe="%SERVER%\ffprobe.exe"
timeout /t 3 /nobreak >nul

start "CasparCG Server" /D "%SERVER%" "%SERVER%\casparcg.exe"

:: Set PGM (channel 1) to about -10 dB once the server accepts commands, as CasparCG resets it on start.
start "CasparCG PGM level" /min powershell -NoProfile -WindowStyle Hidden -Command "for($i=0;$i -lt 60;$i++){try{$c=New-Object Net.Sockets.TcpClient('127.0.0.1',5250);$w=New-Object IO.StreamWriter($c.GetStream());$w.Write('MIXER 1 MASTERVOLUME 0.316'+[char]13+[char]10);$w.Flush();Start-Sleep -Milliseconds 300;$c.Close();break}catch{Start-Sleep 1}}"

timeout /t 5 /nobreak >nul

start "" /D "%CLIENT%" "%CLIENT%\casparcg-client.exe"
