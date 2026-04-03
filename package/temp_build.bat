@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul
cl /c /EHsc /std:c++20 /DNOMINMAX /MT /I"./vendors/webview2/Microsoft.Web.WebView2/build/native/include" /I"./vendors/cef" /I"./vendors/wgpu/win-x64/include" /D_USRDLL /D_WINDLL /Fosrc/native/win/build/nativeWrapper.obj src/native/win/nativeWrapper.cpp
if errorlevel 1 exit /b 1
link /DLL /OUT:src/native/win/build/libNativeWrapper.dll user32.lib ole32.lib shell32.lib shlwapi.lib advapi32.lib dcomp.lib d2d1.lib kernel32.lib comctl32.lib "./vendors/webview2/Microsoft.Web.WebView2/build/native/x64/WebView2LoaderStatic.lib" "./vendors/cef/Release/libcef.lib" "./vendors/cef/build/libcef_dll_wrapper/Release/libcef_dll_wrapper.lib" delayimp.lib /DELAYLOAD:libcef.dll libcmt.lib /IMPLIB:src/native/win/build/libNativeWrapper.lib src/native/win/build/nativeWrapper.obj
