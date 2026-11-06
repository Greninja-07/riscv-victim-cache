@echo off
setlocal enabledelayedexpansion

REM ==============================================================================
REM load_workload.bat - Select & Flash Workloads for Nexys A7 FPGA Demo
REM Group 14: RV32IM with Victim Cache & Stride Prefetcher
REM ==============================================================================

set "PROJ_DIR=%~dp0"
cd /d "%PROJ_DIR%"

if "%~1"=="" goto MENU

set "ARG=%~1"
if "%ARG%"=="1" set "WORKLOAD=conflict_thrash" & goto COPY_FILES
if "%ARG%"=="2" set "WORKLOAD=stride_sum" & goto COPY_FILES
if "%ARG%"=="3" set "WORKLOAD=complex_ops" & goto COPY_FILES
if "%ARG%"=="4" set "WORKLOAD=array_sum" & goto COPY_FILES
if "%ARG%"=="5" set "WORKLOAD=vector_dot" & goto COPY_FILES
if "%ARG%"=="6" set "WORKLOAD=rw_persistence" & goto COPY_FILES
if "%ARG%"=="7" set "WORKLOAD=stride_mixed" & goto COPY_FILES

set "WORKLOAD=%ARG%"
goto COPY_FILES

:MENU
cls
echo ==============================================================================
echo    RV32IM FPGA DEMO - WORKLOAD SELECTOR (Group 14)
echo ==============================================================================
echo  Please select which workload to load into the FPGA BRAM:
echo.
echo    [1] conflict_thrash   (Victim Cache Demo: 30 VC Hits, 6.87x Speedup!)
echo    [2] stride_sum        (Stride Prefetcher Demo: 312 PF Hits, 95%% Stall Reduction!)
echo    [3] complex_ops       (Full Multi-Op Demo: Matrix Inv, Dot, Array, Transpose)
echo    [4] array_sum         (Spatial Locality Demo: Sequential 1D Walk, 93.4%% L1 Hit)
echo    [5] vector_dot        (RV32M MUL Demo: Dual Streaming Vectors, 74.2%% L1 Hit)
echo    [6] rw_persistence    (Dirty Block & VC Swap Persistence)
echo    [7] stride_mixed      (Dual Strided Streams with 16B & 32B Strides)
echo.
echo    [0] Exit
echo ==============================================================================
set /p "CHOICE=Enter choice [1-7]: "

if "%CHOICE%"=="1" set "WORKLOAD=conflict_thrash" & goto COPY_FILES
if "%CHOICE%"=="2" set "WORKLOAD=stride_sum" & goto COPY_FILES
if "%CHOICE%"=="3" set "WORKLOAD=complex_ops" & goto COPY_FILES
if "%CHOICE%"=="4" set "WORKLOAD=array_sum" & goto COPY_FILES
if "%CHOICE%"=="5" set "WORKLOAD=vector_dot" & goto COPY_FILES
if "%CHOICE%"=="6" set "WORKLOAD=rw_persistence" & goto COPY_FILES
if "%CHOICE%"=="7" set "WORKLOAD=stride_mixed" & goto COPY_FILES
if "%CHOICE%"=="0" exit /b 0

echo [ERROR] Invalid selection! Please enter 1-7.
pause
goto MENU

:COPY_FILES
echo.
echo [INFO] Selected workload: %WORKLOAD%
if not exist "sw\%WORKLOAD%_imem.hex" (
    echo [ERROR] Could not find sw\%WORKLOAD%_imem.hex!
    pause
    exit /b 1
)

echo [INFO] Copying hex files to root for synthesis...
copy /y "sw\%WORKLOAD%_imem.hex"   "imem.hex" >nul
copy /y "sw\%WORKLOAD%_dmem.hex"   "dmem.hex" >nul
copy /y "sw\%WORKLOAD%_mem128.hex" "mem128.hex" >nul

if not exist "dashboard" mkdir "dashboard"
echo {"workload": "%WORKLOAD%"} > "dashboard\active_workload.json"

echo [SUCCESS] Workload '%WORKLOAD%' is now staged in imem.hex, mem128.hex, and active_workload.json!
echo.
set /p "REBUILD=Do you want to generate the bitstream now? (Y/N): "
if /i "%REBUILD%"=="Y" (
    call build_bitstream.bat
) else (
    echo.
    echo [INFO] When ready, run 'build_bitstream.bat' to generate the bitstream.
)

pause
