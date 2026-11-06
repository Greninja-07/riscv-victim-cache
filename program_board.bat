@echo off
REM ====================================================================
REM Program Digilent Nexys A7-100T via Vivado JTAG Hardware Server
REM ====================================================================

echo [INFO] Checking Vivado installation...
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    if exist "D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" (
        echo [INFO] Found Vivado in D:\AMDDesignTools\2025.2\Vivado\bin
        set "PATH=D:\AMDDesignTools\2025.2\Vivado\bin;%PATH%"
    ) else (
        echo [ERROR] 'vivado' command not found in PATH!
        pause
        exit /b 1
    )
)

echo [INFO] Programming Nexys A7 with top_fpga.bit...
vivado -mode batch -nojournal -nolog -source scripts/program_fpga.tcl

pause
