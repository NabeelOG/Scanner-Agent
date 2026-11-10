@echo off
setlocal EnableExtensions

title Scanner Agent Installer

REM ============================================================
REM  Scanner Agent Installer
REM
REM  This file can be run from ANY folder. It always copies the
REM  payload to a protected system folder:
REM
REM      %ProgramFiles%\ScannerAgent
REM
REM  Only Administrators and SYSTEM can change or delete files
REM  there, so the user cannot break the agent by accident.
REM
REM  Must sit in the same folder as this file:
REM      scanner-agent.exe
REM      scan.ps1
REM
REM  To remove everything again:
REM      install.bat /uninstall
REM ============================================================

set "TASK_NAME=ScannerAgent"
set "PORT=8081"
set "EXE_SRC=%~dp0scanner-agent.exe"
set "PS1_SRC=%~dp0scan.ps1"

REM ------------------------------------------------------------
REM Pick the install folder. SCANNER_INSTALL_DIR overrides it,
REM which is only used for testing.
REM ------------------------------------------------------------
if defined SCANNER_INSTALL_DIR goto :dir_custom

if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" goto :dir_amd64
set "INSTALL_DIR=%ProgramFiles(x86)%\ScannerAgent"
goto :dir_ready

:dir_amd64
set "INSTALL_DIR=%ProgramFiles%\ScannerAgent"
goto :dir_ready

:dir_custom
set "INSTALL_DIR=%SCANNER_INSTALL_DIR%"

:dir_ready
set "INSTALL_DEST=%INSTALL_DIR%\scanner-agent.exe"
set "PS1_DEST=%INSTALL_DIR%\scan.ps1"
set "LAUNCHER=%INSTALL_DIR%\start-hidden.vbs"
set "LOG_DIR=%ProgramData%\ScannerAgentLogs"
set "TASK_XML=%TEMP%\ScannerAgent-task.xml"
set "TASK_XML_U=%TEMP%\ScannerAgent-task-utf16.xml"
set "STOP_PS1=%TEMP%\ScannerAgent-stop-launcher.ps1"

if /i "%~1"=="/uninstall" set "DO_UNINSTALL=1"

echo.
echo ============================================================
echo                 Scanner Agent Installer
echo ============================================================
echo.
echo Source folder   %~dp0
echo Install to      %INSTALL_DIR%
echo.

REM ------------------------------------------------------------
REM Administrator privileges are needed to write to Program
REM Files, lock down permissions and register the task.
REM ------------------------------------------------------------
echo Checking administrator privileges...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"

if not errorlevel 1 goto :is_admin

echo Not running as Administrator. Requesting access...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevated %1' -Verb RunAs"

exit /b 0

:is_admin
echo [OK] Administrator privileges confirmed.
echo.

if defined DO_UNINSTALL goto :UNINSTALL

REM ------------------------------------------------------------
REM Check the payload is present before touching anything
REM ------------------------------------------------------------
if not exist "%EXE_SRC%" goto :missing_exe
if not exist "%PS1_SRC%" goto :missing_ps1

echo [OK] scanner-agent.exe found.
echo [OK] scan.ps1 found.
echo.

for /f "delims=" %%u in ('whoami') do set "USERDOM=%%u"

REM ------------------------------------------------------------
REM Stop anything already running, then wait for the port to free
REM ------------------------------------------------------------
echo Stopping any previous Scanner Agent...

call :stop_running_agent

REM Confirm it really stopped. A previous copy installed with
REM Administrator rights cannot be killed from a normal prompt, and
REM carrying on to the port check just produces a confusing message
REM about a port the user never knew was in use.
tasklist /FI "IMAGENAME eq scanner-agent.exe" /NH 2>nul | find /I /C "scanner-agent.exe" >nul

if not errorlevel 1 goto :agent_wont_stop

echo [OK] Nothing left running.
echo.

echo Waiting for port %PORT% to be released...

set /a PORT_TRIES=0

:PORT_LOOP
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue; if ($c) { exit 1 } else { exit 0 }" >nul 2>&1

if not errorlevel 1 goto :port_ok

REM A killed process can hold the port for a moment, and Windows can keep
REM sockets in TIME_WAIT for a while, so this waits rather than deciding
REM from a single reading.
set /a PORT_TRIES+=1

if %PORT_TRIES% geq 10 goto :port_busy

ping -n 2 127.0.0.1 >nul
goto :PORT_LOOP

:port_busy
echo.
echo [ERROR] Port %PORT% is still in use after 10 seconds.
echo.
echo Something other than the Scanner Agent is listening on it:
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $q = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; Write-Host ('    PID ' + $_.OwningProcess + '   ' + $q.ProcessName) }" 2>nul
echo.
echo Stop that program, then run this installer again.
echo.
goto :FAILED

:port_ok
echo [OK] Port %PORT% is free.
echo.
goto :port_done

:agent_wont_stop
echo.
echo [ERROR] The Scanner Agent is running but could not be stopped.
echo.
tasklist /FI "IMAGENAME eq scanner-agent.exe" 2>nul | find /I "scanner-agent.exe"
echo.
echo This usually means the running copy was started with Administrator
echo rights. Close it and run this installer again, or right click
echo install.bat and choose "Run as administrator".
echo.
goto :FAILED

:port_done

REM ------------------------------------------------------------
REM Create the folder and copy the payload into it
REM ------------------------------------------------------------
echo Creating install folder...

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

if not exist "%INSTALL_DIR%" goto :mkdir_failed

echo [OK] Folder ready.
echo.

echo Copying Scanner Agent files...

copy /Y "%EXE_SRC%" "%INSTALL_DEST%" >nul
if errorlevel 1 goto :copy_failed

copy /Y "%PS1_SRC%" "%PS1_DEST%" >nul
if errorlevel 1 goto :copy_failed

echo [OK] Files copied.
echo.

REM ------------------------------------------------------------
REM Launcher. wscript.exe has no console window of its own, so it
REM can start the agent with the console hidden. Task Scheduler
REM cannot hide a console window by itself, so without this a black
REM window flashes on every logon.
REM
REM The launcher stays alive and restarts the agent whenever it
REM stops, for any reason. This is deliberately done here rather
REM than relying on the RestartOnFailure setting in the task,
REM which was tested and did not fire. A short pause between
REM attempts stops a broken executable from spinning.
REM ------------------------------------------------------------
echo Creating hidden launcher...

>"%LAUNCHER%" echo Set sh = CreateObject("WScript.Shell")
>>"%LAUNCHER%" echo Set fs = CreateObject("Scripting.FileSystemObject")
>>"%LAUNCHER%" echo base = fs.GetParentFolderName(WScript.ScriptFullName)
>>"%LAUNCHER%" echo exePath = fs.BuildPath(base, "scanner-agent.exe")
>>"%LAUNCHER%" echo exePath = Chr(34) + exePath + Chr(34)
>>"%LAUNCHER%" echo sh.CurrentDirectory = base
>>"%LAUNCHER%" echo Do While True
>>"%LAUNCHER%" echo   sh.Run exePath, 0, True
>>"%LAUNCHER%" echo   WScript.Sleep 15000
>>"%LAUNCHER%" echo Loop

if not exist "%LAUNCHER%" goto :launcher_failed

echo [OK] Launcher created.
echo.

REM ------------------------------------------------------------
REM Clear the Mark of the Web.
REM
REM Files that came out of a downloaded zip carry a Zone.Identifier
REM stream, and Windows then warns that the publisher could not be
REM verified every single time the agent is started. Since the task
REM restarts the agent on every logon, that prompt would come back
REM over and over. Removing the marker is what a local install would
REM have anyway.
REM
REM This has to happen before the folder is locked down below.
REM ------------------------------------------------------------
echo Clearing the download warning marker...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%INSTALL_DIR%' -File | Unblock-File -ErrorAction SilentlyContinue"

echo [OK] Mark of the Web removed.
echo.

REM ------------------------------------------------------------
REM Log folder. The agent runs as the logged on user, which may
REM not be an Administrator, so the user needs write access here.
REM ------------------------------------------------------------
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
icacls "%LOG_DIR%" /grant "*S-1-5-32-545:(OI)(CI)M" >nul 2>&1

REM ------------------------------------------------------------
REM Lock the folder down. Users get read and run only, so the
REM agent cannot be deleted or altered without going through
REM an Administrator. SIDs are used instead of group names so
REM this also works on a non-English Windows.
REM
REM This is done last, after every file has been written. Doing it
REM earlier would block the installer itself from adding the rest.
REM ------------------------------------------------------------
echo Locking down the install folder...

icacls "%INSTALL_DIR%" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" >nul 2>&1

if errorlevel 1 goto :acl_failed

echo [OK] Only Administrators and SYSTEM can modify these files.
echo.

goto :acl_ok

:acl_failed
echo [WARN] Could not set the folder permissions automatically.
echo        Check %INSTALL_DIR% yourself.
echo.

:acl_ok

REM ------------------------------------------------------------
REM Build the task definition.
REM
REM The task is built from XML rather than with schtasks /Create
REM flags because schtasks cannot set the working directory, the
REM restart on failure behaviour, or more than one trigger.
REM
REM Triggers: logon, and every 5 minutes as a keepalive.
REM The task runs in the logged on user's session on purpose.
REM A scanner plugged into that session is only reachable from
REM that session, and session 0 cannot see it.
REM ------------------------------------------------------------
echo Building Scheduled Task definition...

>"%TASK_XML%" (
    echo ^<?xml version="1.0" encoding="UTF-16"?^>
    echo ^<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
    echo   ^<RegistrationInfo^>
    echo     ^<Description^>Scanner Agent^</Description^>
    echo   ^</RegistrationInfo^>
    echo   ^<Triggers^>
    echo     ^<LogonTrigger^>
    echo       ^<Enabled^>true^</Enabled^>
    echo       ^<UserId^>%USERDOM%^</UserId^>
    echo       ^<Delay^>PT10S^</Delay^>
    echo     ^</LogonTrigger^>
    echo     ^<CalendarTrigger^>
    echo       ^<Repetition^>
    echo         ^<Interval^>PT5M^</Interval^>
    echo         ^<StopAtDurationEnd^>false^</StopAtDurationEnd^>
    echo       ^</Repetition^>
    echo       ^<StartBoundary^>2020-01-01T00:00:00^</StartBoundary^>
    echo       ^<Enabled^>true^</Enabled^>
    echo       ^<ScheduleByDay^>
    echo         ^<DaysInterval^>1^</DaysInterval^>
    echo       ^</ScheduleByDay^>
    echo     ^</CalendarTrigger^>
    echo   ^</Triggers^>
    echo   ^<Principals^>
    echo     ^<Principal id="Author"^>
    echo       ^<UserId^>%USERDOM%^</UserId^>
    echo       ^<LogonType^>InteractiveToken^</LogonType^>
    echo       ^<RunLevel^>HighestAvailable^</RunLevel^>
    echo     ^</Principal^>
    echo   ^</Principals^>
    echo   ^<Settings^>
    echo     ^<MultipleInstancesPolicy^>IgnoreNew^</MultipleInstancesPolicy^>
    echo     ^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>
    echo     ^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>
    echo     ^<AllowHardTerminate^>true^</AllowHardTerminate^>
    echo     ^<StartWhenAvailable^>true^</StartWhenAvailable^>
    echo     ^<RunOnlyIfNetworkAvailable^>false^</RunOnlyIfNetworkAvailable^>
    echo     ^<IdleSettings^>
    echo       ^<StopOnIdleEnd^>false^</StopOnIdleEnd^>
    echo       ^<RestartOnIdle^>false^</RestartOnIdle^>
    echo     ^</IdleSettings^>
    echo     ^<AllowStartOnDemand^>true^</AllowStartOnDemand^>
    echo     ^<RestartOnFailure^>
    echo       ^<Interval^>PT1M^</Interval^>
    echo       ^<Count^>999^</Count^>
    echo     ^</RestartOnFailure^>
    echo     ^<Enabled^>true^</Enabled^>
    echo     ^<Hidden^>false^</Hidden^>
    echo     ^<RunOnlyIfIdle^>false^</RunOnlyIfIdle^>
    echo     ^<WakeToRun^>false^</WakeToRun^>
    echo     ^<ExecutionTimeLimit^>PT0S^</ExecutionTimeLimit^>
    echo     ^<Priority^>5^</Priority^>
    echo   ^</Settings^>
    echo   ^<Actions Context="Author"^>
    echo     ^<Exec^>
    echo       ^<Command^>wscript.exe^</Command^>
    echo       ^<Arguments^>"%LAUNCHER%"^</Arguments^>
    echo       ^<WorkingDirectory^>%INSTALL_DIR%^</WorkingDirectory^>
    echo     ^</Exec^>
    echo   ^</Actions^>
    echo ^</Task^>
)

if not exist "%TASK_XML%" goto :xml_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c = [IO.File]::ReadAllText('%TASK_XML%'); [IO.File]::WriteAllText('%TASK_XML_U%', $c, [Text.Encoding]::Unicode)"

if not exist "%TASK_XML_U%" goto :xml_failed

del /Q "%TASK_XML%" >nul 2>&1

echo [OK] Task definition built.
echo.

echo Registering Scheduled Task...

schtasks /Create /TN "%TASK_NAME%" /XML "%TASK_XML_U%" /F >nul 2>&1

if errorlevel 1 goto :task_failed

del /Q "%TASK_XML_U%" >nul 2>&1

schtasks /Query /TN "%TASK_NAME%" >nul 2>&1
if errorlevel 1 goto :task_failed

echo [OK] Scheduled Task registered.
echo.

REM ------------------------------------------------------------
REM Start it now rather than waiting for the next logon.
REM
REM Started directly rather than through the launcher, because the
REM launcher waits for the agent and would hold up this script.
REM ------------------------------------------------------------
echo Starting Scanner Agent...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%INSTALL_DEST%' -WorkingDirectory '%INSTALL_DIR%' -WindowStyle Hidden"

if errorlevel 1 goto :start_cmd_failed

echo Waiting for the agent to answer...

set /a ATTEMPTS=0

:WAIT_LOOP
set /a ATTEMPTS+=1

REM 127.0.0.1 and not localhost. localhost can resolve to the
REM IPv6 address first on some machines, and the agent only
REM listens on IPv4, which made this check fail even when the
REM agent was running fine.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$r = try { Invoke-WebRequest -Uri 'http://127.0.0.1:%PORT%/health' -UseBasicParsing -TimeoutSec 2 } catch { $null }; if ($r -and $r.StatusCode -eq 200) { exit 0 } else { exit 1 }"

if not errorlevel 1 goto :SUCCESS

if %ATTEMPTS% geq 15 goto :START_FAILED

ping -n 2 127.0.0.1 >nul
goto :WAIT_LOOP

REM ============================================================
REM Success
REM ============================================================

:SUCCESS
echo.
echo ============================================================
echo                 INSTALLATION SUCCESSFUL
echo ============================================================
echo.
echo Installed to     %INSTALL_DIR%
echo Task             %TASK_NAME%
echo Logs             %LOG_DIR%
echo.
echo Health check:
echo     curl http://127.0.0.1:%PORT%/health
echo.
echo Scan a page:
echo     curl -f -X POST http://127.0.0.1:%PORT%/scan -o scan.jpg
echo.
echo The agent starts on logon and restarts itself if it stops.
echo The user cannot delete the installed files by accident.
echo.
echo ============================================================
echo.
exit /b 0

REM ============================================================
REM Uninstall
REM ============================================================

:UNINSTALL
echo Removing Scanner Agent...

call :stop_running_agent

REM The folder is removed with a few retries because Windows can hold
REM a file open for a moment after the process using it has gone.
set /a REMOVE_TRIES=0

:REMOVE_LOOP
if not exist "%INSTALL_DIR%" goto :REMOVE_OK

rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1

if not exist "%INSTALL_DIR%" goto :REMOVE_OK

set /a REMOVE_TRIES+=1

if %REMOVE_TRIES% geq 5 goto :REMOVE_STUCK

REM ping is used to pause rather than "timeout", because timeout
REM refuses to run when standard input is redirected and prints an
REM error instead of waiting.
ping -n 2 127.0.0.1 >nul
goto :REMOVE_LOOP

:REMOVE_STUCK
echo.
echo [WARN] Some files could not be deleted. Close anything using them
echo        and delete this folder by hand:
echo        %INSTALL_DIR%
echo.
echo [OK] Task and process removed.
echo.
exit /b 0

:REMOVE_OK
echo [OK] Task, process and files removed.
echo.
exit /b 0

REM ============================================================
REM Failure messages
REM ============================================================

:missing_exe
echo.
echo [ERROR] scanner-agent.exe is missing.
echo.
echo Put these three files in the same folder:
echo     scanner-agent.exe
echo     scan.ps1
echo     install.bat
echo.
goto :FAILED

:missing_ps1
echo.
echo [ERROR] scan.ps1 is missing.
echo.
echo Put these three files in the same folder:
echo     scanner-agent.exe
echo     scan.ps1
echo     install.bat
echo.
goto :FAILED

:mkdir_failed
echo.
echo [ERROR] Could not create %INSTALL_DIR%
echo.
goto :FAILED

:copy_failed
echo.
echo [ERROR] Could not copy the Scanner Agent files.
echo.
goto :FAILED

:launcher_failed
echo.
echo [ERROR] Could not create the hidden launcher.
echo.
goto :FAILED

:start_cmd_failed
echo.
echo [ERROR] Could not start the Scanner Agent process.
echo.
goto :FAILED

:xml_failed
echo.
echo [ERROR] Could not build the Scheduled Task definition.
echo.
goto :FAILED

:task_failed
echo.
echo [ERROR] Could not register the Scheduled Task.
echo.
goto :FAILED

:START_FAILED
echo.
echo ============================================================
echo             SCANNER AGENT FAILED TO START
echo ============================================================
echo.
echo The files were installed but the agent did not answer on:
echo.
echo     http://127.0.0.1:%PORT%/health
echo.
echo within 15 seconds.
echo.
echo Check the log:
echo     %LOG_DIR%
echo.
echo Or run it by hand to see any error:
echo     "%INSTALL_DEST%"
echo.
echo ============================================================
echo.
goto :FAILED

:FAILED
echo.
echo ============================================================
echo                    INSTALLATION FAILED
echo ============================================================
echo.
echo Fix the problem above and run install.bat again.
echo.
echo ============================================================
echo.
pause
exit /b 1

REM ============================================================
REM Shared: stop the running agent and remove its task.
REM
REM Order matters here. The launcher is a supervisor that restarts
REM the agent within seconds, so it has to be stopped before the
REM agent is killed. Killing the agent first just makes it come
REM straight back, and the port is still held a moment later.
REM
REM Only the launcher belonging to this install folder is stopped,
REM so unrelated wscript processes are left alone.
REM ============================================================

:stop_running_agent
>"%STOP_PS1%" echo $ErrorActionPreference = 'SilentlyContinue'
>>"%STOP_PS1%" echo Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" ^| Where-Object { $_.CommandLine -like '*%LAUNCHER%*' } ^| ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%STOP_PS1%" >nul 2>&1
del /Q "%STOP_PS1%" >nul 2>&1

schtasks /End /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
taskkill /F /IM scanner-agent.exe >nul 2>&1
exit /b 0
