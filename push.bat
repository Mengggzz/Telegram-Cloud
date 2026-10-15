@echo off
setlocal enabledelayedexpansion
title Push and Commit TGCloud

cd /d "C:\Users\NAN\Desktop\tgcloud"

echo ========================================================
echo        TGCloud App - Auto Commit and Push
echo       Target: https://github.com/Mengggzz/Telegram-Cloud
echo ========================================================
echo.

:: 1. Tarik pembaruan remote terlebih dahulu untuk mencegah konflik
echo [*] Melakukan sinkronisasi dengan remote GitHub...
git pull --rebase origin main
if %ERRORLEVEL% neq 0 (
    echo [WARNING] Rebase gagal atau terjadi konflik. Periksa status git secara manual.
    pause
    exit /b %ERRORLEVEL%
)

:: 2. Cek apakah ada perubahan file yang belum di-commit
git status --porcelain > "%TEMP%\tgcloud_git_status.txt"
set "STATUS="
set /p STATUS=<"%TEMP%\tgcloud_git_status.txt"
del "%TEMP%\tgcloud_git_status.txt" 2>nul

if "!STATUS!"=="" (
    echo [INFO] Tidak ada perubahan file lokal yang belum di-commit.
    echo Mengecek commit lokal yang belum ter-push...
    git push origin main
    goto CHECK_TAG
)

:: 3. Ambil pesan commit dari argumen atau prompt input
set "MSG=%~1"
if "!MSG!"=="" (
    set /p "MSG=Masukkan pesan commit (tekan Enter untuk 'chore: update project'): "
)

if "!MSG!"=="" (
    set "MSG=chore: update project"
)

echo.
echo [1/3] Menambahkan file ke staging...
git add -A

echo.
echo [2/3] Membuat commit: "!MSG!"...
git commit -m "!MSG!"

echo.
echo [3/3] Mendorong perubahan ke GitHub (branch: main)...
git push origin main

if %ERRORLEVEL% neq 0 (
    echo.
    echo ========================================================
    echo   [ERROR] Push gagal. Periksa koneksi internet / auth git.
    echo ========================================================
    echo.
    pause
    exit /b %ERRORLEVEL%
)

:CHECK_TAG
echo.
echo ========================================================
echo   BERHASIL! Perubahan berhasil terdorong ke GitHub.
echo ========================================================
echo.

:: Opsi buat tag rilis untuk trigger GitHub Actions APK build
set /p "CREATE_TAG=Buat tag rilis baru untuk trigger build APK di GitHub Actions? (y/N): "
if /i "!CREATE_TAG!"=="y" (
    set /p "TAG_NAME=Masukkan nama tag (contoh: v1.0.2): "
    if not "!TAG_NAME!"=="" (
        echo Mendorong tag !TAG_NAME!...
        git tag "!TAG_NAME!"
        git push origin "!TAG_NAME!"
        echo Tag !TAG_NAME! berhasil dikirim! GitHub Actions akan otomatis membuat APK.
    )
)

echo.
echo Jendela akan tertutup otomatis dalam 5 detik...
timeout /t 5 >nul
