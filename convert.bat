@echo off
setlocal
set "STM32_OPERATION_NAME=Conversion"
call "%~dp0build.bat" convert %*
set "STM32_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %STM32_EXIT_CODE%
