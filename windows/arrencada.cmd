@echo off
rem Llançador per fer doble clic: executa arrencada.ps1 amb l'usuari actual.
rem Aquest fitxer MAI interpreta text escrit per la persona: només passa els arguments
rem de la línia d'ordres. Si no s'indica -Repo, el pregunta el propi PowerShell.
rem
rem IMPORTANT: si IT imposa una politica AllSigned o AppLocker, aquest llancador
rem quedara bloquejat. Llavors IT ha de signar arrencada.ps1 o executar-lo des de
rem NinjaOne com a l'usuari amb sessio iniciada (no com a SYSTEM).
rem
rem Us: arrencada.cmd [-Repo ORG/NOM] [-Directori DIR] [-Correu EMAIL] [-NoObrir] [-SenseGentleShell]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0arrencada.ps1" %*
set "CODI=%ERRORLEVEL%"
echo.
echo [arrencada] Sortida amb codi %CODI%.
pause
exit /b %CODI%
