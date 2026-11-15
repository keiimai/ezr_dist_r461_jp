@echo off
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
if /i "%~1"=="--gui-worker" goto worker

set "EZR_ROOT=%CD%"
set "EZR_GUI_SCRIPT=%CD%\launcher\windows_gui.ps1"
powershell -NoLogo -NoProfile -Command "Get-ChildItem -LiteralPath $env:EZR_ROOT -Recurse -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
if exist "%EZR_GUI_SCRIPT%" goto open_window
call :load_messages
call :say no_gui
pause
exit /b 1
:open_window
start "" powershell -NoLogo -NoProfile -STA -WindowStyle Hidden -Command "& ([ScriptBlock]::Create((Get-Content -Raw -Encoding UTF8 -LiteralPath $env:EZR_GUI_SCRIPT)))"
exit /b 0

:worker
set "CONDITION_DIRTY=0"
set "CONDITION_WRITES=0"
set "CONDITION_START=0"
set "ROUTINE_FILE="
if "%EZR_ROUTINE_RECORD%"=="0" goto routine_initialized
if not exist outputs mkdir outputs >nul 2>&1
:runtime_name
set "ROUTINE_ID=%RANDOM%_%RANDOM%_%RANDOM%"
if exist "outputs\runtime_%ROUTINE_ID%.jsonl" goto runtime_name
set "ROUTINE_FILE=outputs\runtime_%ROUTINE_ID%.jsonl"
call :routine_result 0
> "%ROUTINE_FILE%" echo {"schema_version":"1.0","record_kind":"ezr_launcher","run_id":"%ROUTINE_ID%","platform":"Windows","elapsed_clock":"local_time_of_day","elapsed_resolution_seconds":0.01,"ezr_analysis":"not_evaluated"}
if errorlevel 1 (
  call :load_messages
  call :say record_unavailable 1>&2
  set "ROUTINE_FILE="
)
:routine_initialized
call :record begin launcher null

call :load_messages



call :record begin docker_cli null
where docker >nul 2>&1
if not errorlevel 1 goto docker_cli_checked
set "DOCKER_BIN=%LOCALAPPDATA%\Programs\DockerDesktop\resources\bin"
if not exist "%DOCKER_BIN%\docker.exe" set "DOCKER_BIN=%ProgramFiles%\Docker\Docker\resources\bin"
if exist "%DOCKER_BIN%\docker.exe" set "PATH=%DOCKER_BIN%;%PATH%"
where docker >nul 2>&1
:docker_cli_checked
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end docker_cli %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
if errorlevel 1 (
  set "MSG=no_docker"
  goto fail
)
call :record begin project_files null
if not exist "docker-compose.yml" (
  call :record end project_files 1
  set "MSG=not_project"
  goto fail
)

call :record end project_files 0

call :record begin docker_ready null
docker info >nul 2>&1
if not errorlevel 1 goto docker_ready
call :record requested docker_desktop null
call :say starting_docker
set "DOCKER_APP=%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe"
if not exist "%DOCKER_APP%" set "DOCKER_APP=%LOCALAPPDATA%\Programs\DockerDesktop\DockerDesktop.exe"
if not exist "%DOCKER_APP%" set "DOCKER_APP=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not exist "%DOCKER_APP%" goto docker_app_missing
start "" "%DOCKER_APP%"
goto docker_wait_start
:docker_app_missing
call :say open_docker_yourself
:docker_wait_start
set /a TRIES=0
:wait_docker
ping -n 3 127.0.0.1 >nul
docker info >nul 2>&1
if not errorlevel 1 goto docker_ready
set /a TRIES+=1
if %TRIES% lss 60 goto wait_docker
call :record timeout docker_ready 1
set "MSG=docker_not_ready"
goto fail
:docker_ready
call :record end docker_ready 0

set "PROJDIR=%CD%"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$b = ((Split-Path -Leaf $env:PROJDIR).ToLower() -replace '[^a-z0-9]', ''); if (-not $b) { $b = 'r' }; $h = [BitConverter]::ToUInt32([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($env:PROJDIR)), 0) %% 1000000; '{0}-{1:D6}' -f $b, $h"`) do set "NAME=%%i"
if not defined NAME (
  set "MSG=no_name"
  goto fail
)

set "ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=%PROCESSOR_ARCHITEW6432%"
set "PLATFORM=linux/amd64"
if /i "%ARCH%"=="ARM64" set "PLATFORM=linux/arm64"
set "OVDIR=%TEMP%\rlauncher_%RANDOM%%RANDOM%"
mkdir "%OVDIR%" >nul 2>&1

call :say preparing
set "VCS_REF="
if exist ".git" for /f "delims=" %%i in ('git describe --always --dirty --abbrev^=40 --exclude^=* 2^>nul') do set "VCS_REF=%%i"
if not defined VCS_REF if exist "TEMPLATE_VERSION.txt" for /f "usebackq tokens=1,3" %%a in ("TEMPLATE_VERSION.txt") do if "%%a"=="template" set "VCS_REF=%%b"
if not defined VCS_REF set "VCS_REF=unknown"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)"`) do set "BUILD_DATE=%%i"

call :build_dev
if errorlevel 1 goto relock
call :record begin package_check null
docker compose -p %NAME% -f docker-compose.yml run --rm --user rstudio dev Rscript --vanilla tools/make_lockfile.R --check <nul >nul 2>&1
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end package_check %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
if not errorlevel 1 goto packages_ok
:relock
call :say relocking
set "MSG=build_failed"
call :record begin bootstrap_build null
docker build --platform %PLATFORM% --target bootstrap -t %NAME%:bootstrap .
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end bootstrap_build %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
if errorlevel 1 goto fail_cleanup
set "MSG=relock_failed"
call :record begin package_relock null
docker compose -p %NAME% -f docker-compose.yml run --rm --user rstudio -v renv-cache:/opt/renv/cache lock Rscript --vanilla tools/make_lockfile.R <nul
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end package_relock %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
if errorlevel 1 goto fail_cleanup
set "MSG=build_failed"
call :build_dev
if errorlevel 1 goto fail_cleanup
:packages_ok
if defined ROUTINE_FILE if exist "%OVDIR%\image-id" (
  for /f "usebackq delims=" %%i in ("%OVDIR%\image-id") do >> "%ROUTINE_FILE%" echo {"event":"build_identity","built_image_id":"%%i","target":"%PLATFORM%","image_tag":"%NAME%:dev","built_at":"%BUILD_DATE%"}
)

call :record begin container_start null
docker compose -p %NAME% -f docker-compose.yml up -d dev
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end container_start %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
if errorlevel 1 (
  set "MSG=up_failed"
  goto fail_cleanup
)
call :record begin rstudio_ready null
set /a TRIES=0
:wait_rstudio
ping -n 2 127.0.0.1 >nul
set "HOSTPORT="
for /f "delims=" %%p in ('docker compose -p %NAME% -f docker-compose.yml port dev 8787 2^>nul') do set "HOSTPORT=%%p"
if defined HOSTPORT (
  curl.exe -fs --max-time 2 -o nul "http://%HOSTPORT%/" && goto rstudio_ready
)
set /a TRIES+=1
if %TRIES% lss 90 goto wait_rstudio
call :record timeout rstudio_ready 1
call :record begin container_stop_remove null
docker compose -p %NAME% -f docker-compose.yml down
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end container_stop_remove %ROUTINE_RC%
call :routine_result %ROUTINE_RC%
set "MSG=no_response"
goto fail_cleanup
:rstudio_ready
call :record end rstudio_ready 0
call :condition_flush
set "URL=http://localhost:%HOSTPORT:*:=%"
echo.
call :say ready "%URL%"
call :say browser_hint_gui
echo.
echo EZR_UI^|READY^|%URL%

:gui_wait
set "ACTION="
call :routine_result 0
set /p "ACTION="
if errorlevel 1 goto gui_disconnected
if /i "%ACTION%"=="stop" goto gui_stop
if /i "%ACTION%"=="force-stop" goto gui_force_stop
goto gui_wait

:gui_stop
call :record requested shutdown null
set "RUNNING_DEV="
docker compose -p %NAME% -f docker-compose.yml ps --status running -q dev >nul 2>&1
if errorlevel 1 goto gui_check_records
for /f "delims=" %%c in ('docker compose -p %NAME% -f docker-compose.yml ps --status running -q dev 2^>nul') do set "RUNNING_DEV=%%c"
if defined RUNNING_DEV goto gui_check_records
call :record skipped records_check null
goto gui_down
:gui_check_records
docker compose -p %NAME% -f docker-compose.yml exec -T dev Rscript --vanilla -e "source('R/project_ezr.R');quit(status=ezr_records_status())" <nul
set "RECORDS_RC=%ERRORLEVEL%"
if "%RECORDS_RC%"=="0" goto gui_down
if not "%RECORDS_RC%"=="2" goto gui_stop_failed
echo EZR_UI^|WAIT_RECORDS
goto gui_wait

:gui_force_stop
call :record requested forced_shutdown null

:gui_down
call :say stopping
call :record begin container_stop_remove null
docker compose -p %NAME% -f docker-compose.yml down
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end container_stop_remove %ROUTINE_RC%
if not "%ROUTINE_RC%"=="0" goto gui_stop_failed
set "REMAINING="
docker compose -p %NAME% -f docker-compose.yml ps -aq >nul 2>&1
if errorlevel 1 set "REMAINING=unknown"
for /f "delims=" %%c in ('docker compose -p %NAME% -f docker-compose.yml ps -aq 2^>nul') do set "REMAINING=%%c"
if not defined REMAINING goto gui_stopped
call :record end container_stop_verify 1
goto gui_stop_failed
:gui_stopped
rmdir /s /q "%OVDIR%" >nul 2>&1
call :say stopped
call :record launcher_exit launcher 0
if %CONDITION_WRITES% gtr 0 set "CONDITION_DIRTY=1"
call :condition_flush
exit /b 0

:gui_stop_failed
call :say stop_failed
echo EZR_UI^|STOP_FAILED
goto gui_wait

:gui_disconnected
call :say disconnected
rmdir /s /q "%OVDIR%" >nul 2>&1
call :record launcher_exit launcher 1
if %CONDITION_WRITES% gtr 0 set "CONDITION_DIRTY=1"
call :condition_flush
exit /b 1

:fail_cleanup
rmdir /s /q "%OVDIR%" >nul 2>&1
:fail
call :record launcher_exit launcher 1
if %CONDITION_WRITES% gtr 0 set "CONDITION_DIRTY=1"
call :condition_flush
echo.
call :say %MSG%
exit /b 1

:build_dev
call :record begin build null
docker build --iidfile "%OVDIR%\image-id" --platform %PLATFORM% --target dev --build-arg BUILD_DATE=%BUILD_DATE% --build-arg VCS_REF=%VCS_REF% --build-arg IMAGE_NAME=%NAME% -t %NAME%:dev .
set "ROUTINE_RC=%ERRORLEVEL%"
call :record end build %ROUTINE_RC%
exit /b %ROUTINE_RC%

:load_messages
for /f "usebackq tokens=1,* delims==" %%a in (`powershell -NoLogo -NoProfile -Command "[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); Get-Content -Encoding UTF8 -LiteralPath 'launcher\start_messages.txt' -ErrorAction SilentlyContinue | Where-Object { $_ -cmatch '^[a-z_]+=' }"`) do set "EZR_MSG_%%a=%%b"
exit /b 0

:say
set "SAY_ARG=%~2"
setlocal EnableDelayedExpansion
set "SAY_TEXT="
for %%k in (%~1) do set "SAY_TEXT=!EZR_MSG_%%k!"
if defined SAY_TEXT (
  set "SAY_TEXT=!SAY_TEXT:{0}=%SAY_ARG%!"
  echo(!SAY_TEXT!
) else (
  echo([start_messages.txt: %~1] !SAY_ARG!
)
endlocal
exit /b 0

:record
if not defined ROUTINE_FILE exit /b 0
set "ROUTINE_CLOCK=%TIME: =0%"
call :routine_result 0
>> "%ROUTINE_FILE%" echo {"event":"%~1","phase":"%~2","local_clock":"%ROUTINE_CLOCK%","exit_code":%~3}
if errorlevel 1 (
  call :say record_unavailable 1>&2
  set "ROUTINE_FILE="
)
call :condition_check %~1 %~2 %~3
exit /b 0

:routine_result
exit /b %~1

:condition_clock
set "CONDITION_CLOCK=%TIME: =0%"
set /a "CONDITION_TICK=((1%CONDITION_CLOCK:~0,2%-100)*3600+(1%CONDITION_CLOCK:~3,2%-100)*60+(1%CONDITION_CLOCK:~6,2%-100))*100+(1%CONDITION_CLOCK:~9,2%-100)" >nul 2>&1
exit /b 0

:condition_check
if "%EZR_CONDITIONAL_RECORD%"=="0" exit /b 0
if "%~1"=="timeout" (
  call :condition_event timeout %~2 %~3 null null
  exit /b 0
)
if "%~1"=="launcher_exit" (
  if not "%~3"=="0" call :condition_event launcher_failed launcher %~3 null null
  exit /b 0
)
if not "%~1"=="begin" if not "%~1"=="end" exit /b 0
call :condition_clock
if "%~1"=="begin" (
  set "CONDITION_START=%CONDITION_TICK%"
  exit /b 0
)
if not "%~3"=="0" call :condition_event command_failed %~2 %~3 null null
set /a "CONDITION_DURATION=((CONDITION_TICK-CONDITION_START+8640000) %% 8640000)/100" >nul 2>&1
set "CONDITION_INPUT=0"
set "CONDITION_FALLBACK=0"
if "%~2"=="docker_ready" (set "CONDITION_INPUT=%EZR_SLOW_DOCKER_SECONDS%"&set "CONDITION_FALLBACK=60")
if "%~2"=="build" (set "CONDITION_INPUT=%EZR_SLOW_BUILD_SECONDS%"&set "CONDITION_FALLBACK=900")
if "%~2"=="bootstrap_build" (set "CONDITION_INPUT=%EZR_SLOW_BUILD_SECONDS%"&set "CONDITION_FALLBACK=900")
if "%~2"=="package_relock" (set "CONDITION_INPUT=%EZR_SLOW_BUILD_SECONDS%"&set "CONDITION_FALLBACK=900")
if "%~2"=="container_start" (set "CONDITION_INPUT=%EZR_SLOW_START_SECONDS%"&set "CONDITION_FALLBACK=30")
if "%~2"=="rstudio_ready" (set "CONDITION_INPUT=%EZR_SLOW_START_SECONDS%"&set "CONDITION_FALLBACK=30")
if "%~2"=="package_check" (set "CONDITION_INPUT=%EZR_SLOW_START_SECONDS%"&set "CONDITION_FALLBACK=30")
if "%~2"=="container_stop_remove" (set "CONDITION_INPUT=%EZR_SLOW_STOP_SECONDS%"&set "CONDITION_FALLBACK=30")
call :condition_threshold
if %CONDITION_LIMIT% gtr 0 if %CONDITION_DURATION% geq %CONDITION_LIMIT% call :condition_event slow_phase %~2 %~3 %CONDITION_DURATION% %CONDITION_LIMIT%
exit /b 0

:condition_threshold
set "CONDITION_LIMIT=%CONDITION_FALLBACK%"
if not defined CONDITION_INPUT exit /b 0
if not "%CONDITION_INPUT:~5,1%"=="" exit /b 0
set "CONDITION_CHECK=X%CONDITION_INPUT%"
set "CONDITION_CHECK=%CONDITION_CHECK:0=%"
set "CONDITION_CHECK=%CONDITION_CHECK:1=%"
set "CONDITION_CHECK=%CONDITION_CHECK:2=%"
set "CONDITION_CHECK=%CONDITION_CHECK:3=%"
set "CONDITION_CHECK=%CONDITION_CHECK:4=%"
set "CONDITION_CHECK=%CONDITION_CHECK:5=%"
set "CONDITION_CHECK=%CONDITION_CHECK:6=%"
set "CONDITION_CHECK=%CONDITION_CHECK:7=%"
set "CONDITION_CHECK=%CONDITION_CHECK:8=%"
set "CONDITION_CHECK=%CONDITION_CHECK:9=%"
if not "%CONDITION_CHECK%"=="X" exit /b 0
set "CONDITION_NUMBER=00000%CONDITION_INPUT%"
set /a "CONDITION_NUMBER=1%CONDITION_NUMBER:~-5%-100000" >nul 2>&1
if %CONDITION_NUMBER% leq 86400 set "CONDITION_LIMIT=%CONDITION_NUMBER%"
exit /b 0

:condition_event
if not defined ROUTINE_FILE exit /b 0
call :routine_result 0
>> "%ROUTINE_FILE%" echo {"event":"condition","rule":"%~1","phase":"%~2","exit_code":%~3,"observed_seconds":%~4,"threshold_seconds":%~5}
if not errorlevel 1 set "CONDITION_DIRTY=1"
exit /b 0

:condition_flush
if not "%CONDITION_DIRTY%"=="1" exit /b 0
if %CONDITION_WRITES% geq 2 exit /b 0
if not defined ROUTINE_FILE exit /b 0
set "CONDITION_DIRTY=0"
set /a CONDITION_WRITES+=1 >nul
if not exist diagnose_windows.bat (
  call :say diagnose_missing diagnose_windows.bat 1>&2
  exit /b 0
)
call diagnose_windows.bat --incident=runtime_%ROUTINE_ID%.jsonl --no-pause
if errorlevel 1 call :say incident_failed 1>&2
exit /b 0
