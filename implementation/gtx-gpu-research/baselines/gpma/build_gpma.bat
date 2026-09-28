@echo off
rem Builds the GPMA+ benchmark twice on identical workload streams:
rem   gpma_port.exe     - Windows port (dynamic-parallelism rebalancing flattened to a host loop)
rem   gpma_upstream.exe - pristine upstream gpma_demo (commit 080aa6d) with legacy CDP1 dynamic parallelism
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
set B=C:\Vivek\RM\gpu-stm-dynamic-graphs\baselines
set H=%~dp0
if not exist "%H%..\..\bin" mkdir "%H%..\..\bin"
echo == port
nvcc -O3 -std=c++17 -w -arch=sm_89 -rdc=true -DGPMA_VARIANT=\"port\" -I"%B%\gpma_port" "%H%bench_gpma.cu" -o "%H%..\..\bin\gpma_port.exe" -lcudadevrt
echo == upstream (CDP1)
nvcc -O3 -std=c++17 -w -arch=sm_89 -rdc=true -DCUDA_FORCE_CDP1_IF_SUPPORTED -DGPMA_VARIANT=\"upstream\" -I"%H%upstream_patched" "%H%bench_gpma.cu" -o "%H%..\..\bin\gpma_upstream.exe" -lcudadevrt
