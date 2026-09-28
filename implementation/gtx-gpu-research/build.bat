@echo off
rem Usage: build.bat <name>   (compiles src\<name>.cu -> bin\<name>.exe)
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if not exist "%~dp0bin" mkdir "%~dp0bin"
nvcc -O3 -std=c++17 -arch=sm_89 -lineinfo -Xcompiler "/O2 /EHsc" -I"%~dp0src" "%~dp0src\%1.cu" -o "%~dp0bin\%1.exe"
