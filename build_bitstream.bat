@echo off
REM ====================================================================
REM Build Script to Generate Bitstream using Vivado
REM Target: Nexys A7 100T (top_fpga with Victim Cache & Profiler)
REM ====================================================================

echo [INFO] Checking Vivado installation...
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    if exist "D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" (
        echo [INFO] Found Vivado in D:\AMDDesignTools\2025.2\Vivado\bin
        set "PATH=D:\AMDDesignTools\2025.2\Vivado\bin;%PATH%"
    ) else (
        echo [ERROR] 'vivado' command not found in PATH!
        echo Please run this from the Vivado Command Prompt or add Vivado bin to PATH.
        pause
        exit /b 1
    )
)

echo [INFO] Running Vivado batch flow for bitstream generation...
vivado -mode batch -nojournal -nolog -source scripts/vivado_bitstream.tcl

if %errorlevel% equ 0 (
    echo.
    echo ==================================================================
    echo [SUCCESS] Bitstream generation complete: top_fpga.bit
    echo ==================================================================
) else (
    echo.
    echo ==================================================================
    echo [ERROR] Bitstream generation failed! Check reports/ for details.
    echo ==================================================================
)
pause
