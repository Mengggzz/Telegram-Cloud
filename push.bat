@echo off
setlocal enabledelayedexpansion
title Push and Commit TGCloud

cd /d "C:\Users\NAN\Desktop\tgcloud"

echo ========================================================
echo        TGCloud App - Auto Commit and Push
echo       Target: https://github.com/Mengggzz/Telegram-Cloud
echo ========================================================
echo.

:: 1. Cek apakah ada perubahan file yang belum di-commit
git status --porcelain > "%TEMP%\tgcloud_status.tmp" 2>nul

set HAS_CHANGES=0
for %%A in ("%TEMP%\tgcloud_status.tmp") do (
    if %%~zA gtr 0 set HAS_CHANGES=1
)
del "%TEMP%\tgcloud_status.tmp" 2>nul

if "!HAS_CHANGES!"=="1" (
    echo [INFO] Ditemukan file yang dimodifikasi / belum ditrack:
    git status -s
    echo.

    set "MSG="
    if not "%~1"=="" set "MSG=%~1"
    if not defined MSG (
        set /p "MSG=Masukkan pesan commit (tekan Enter untuk 'chore: update project'): "
    )
    if "!MSG!"==" " set "MSG="
    if not defined MSG set "MSG=chore: update project"
    if "!MSG!"=="" set "MSG=chore: update project"

    echo.
    echo [1/3] Menambahkan file ke staging [git add -A]...
    git add -A

    echo.
    echo [2/3] Membuat commit: "!MSG!"...
    git commit -m "!MSG!"
    if !ERRORLEVEL! neq 0 (
        echo.
        echo [ERROR] Gagal membuat commit.
        pause
        exit /b !ERRORLEVEL!
    )
) else (
    echo [INFO] Tidak ada file kerja yang dimodifikasi.
)

:: 2. Tarik update terbaru dari remote jika ada
echo.
echo [*] Sinkronisasi dengan remote GitHub [git pull --rebase origin main]...
git pull --rebase origin main
if %ERRORLEVEL% neq 0 (
    echo.
    echo [WARNING] Rebase gagal atau terjadi konflik. Periksa status git secara manual.
    pause
    exit /b %ERRORLEVEL%
)

:: 3. Mendorong perubahan ke GitHub
echo.
echo [3/3] Mendorong perubahan ke GitHub [git push origin main]...
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

echo.
echo ========================================================
echo   BERHASIL! Perubahan berhasil terdorong ke GitHub.
echo ========================================================
echo.

for /f "tokens=*" %%T in ('git describe --tags --abbrev^=0 2^>nul') do set "LATEST_TAG=%%T"
if not "!LATEST_TAG!"=="" (
    echo Tag rilis terakhir: !LATEST_TAG!
) else (
    echo Belum ada tag rilis.
)
echo.

set /p "CREATE_TAG=Buat tag rilis baru untuk trigger build APK & Windows Desktop di GitHub Actions? (y/N): "
if /i "!CREATE_TAG!"=="y" (
    set /p "TAG_NAME=Masukkan nama tag baru (contoh: v1.0.5): "
    if not "!TAG_NAME!"=="" (
        echo Mendorong tag !TAG_NAME!...
        git tag "!TAG_NAME!"
        git push origin "!TAG_NAME!"
        if !ERRORLEVEL! equ 0 (
            echo Tag !TAG_NAME! berhasil dikirim! GitHub Actions akan otomatis membuat APK dan Desktop zip.
        ) else (
            echo [ERROR] Gagal membuat/mendorong tag !TAG_NAME!.
        )
    )
)

echo.
echo Tekan tombol apa saja untuk menutup jendela...
pause >nul
