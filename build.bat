@echo off
setlocal
pushd "%~dp0"

if not defined STM32_OPERATION_NAME set "STM32_OPERATION_NAME=Build"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell 7 ^(pwsh.exe^) was not found in PATH.
    echo Install PowerShell 7 or add its directory to PATH.
    popd
    echo.
    echo [%STM32_OPERATION_NAME% FAILED] Exit code: 1
    echo Press any key to close this window...
    pause >nul
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0stm32.ps1" %*
set "STM32_EXIT_CODE=%ERRORLEVEL%"

if not "%STM32_EXIT_CODE%"=="0" (
    echo.
    echo [%STM32_OPERATION_NAME% FAILED] Exit code: %STM32_EXIT_CODE%
) else (
    echo.
    echo [%STM32_OPERATION_NAME% SUCCESS] Operation completed successfully.
)

popd
echo.
echo Press any key to close this window...
pause >nul
exit /b %STM32_EXIT_CODE%
