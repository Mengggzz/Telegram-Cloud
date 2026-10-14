# Spesifikasi Desain — Aplikasi Cloud Storage via Telegram (TGCloud)

**Tanggal:** 14 Oktober 2026  
**Status:** Approved by User  
**Target Platform:** Android (minSdk 26, targetSdk 34+)  
**Package:** `com.tgcloud`  
**Lokasi Proyek:** `C:\Users\NAN\Desktop\tgcloud`

---

## 1. Ringkasan & Tujuan

Aplikasi Android berbasis Flutter untuk penyimpanan cloud pribadi menggunakan Telegram Bot API dan channel privat sebagai media penyimpanan backend. File berukuran besar dipecah menjadi chunk (±15MB), dienkripsi secara client-side menggunakan AES-256-GCM dengan kunci turunan PIN pengguna, diunggah ke channel Telegram, dan metadata disimpan di database SQLite lokal.

Fitur utama meliputi:
- Upload manual file (termasuk video/arsip besar) dengan streaming chunking dan enkripsi client-side.
- Download berurutan dengan streaming reassembly langsung ke disk dan verifikasi integritas SHA-256 ganda (per-chunk dan end-to-end).
- UI modern bernuansa dark maskulin (charcoal `#121212` dan aksen amber `#FF9800`) berbahasa Indonesia.
- Ketahanan proses transfer melalui Android Foreground Service.
- Pencadangan berkala/manual untuk folder media lokal dengan deduplikasi otomatis.

---

## 2. Kredensial & Keamanan

### 2.1 Parameter `--dart-define`
Kredensial Telegram tidak pernah di-hardcode ke dalam kode sumber:
- `TG_BOT_TOKEN`: Token bot resmi dari Telegram BotFather.
- `TG_CHAT_ID`: ID numerik channel privat Telegram tempat bot dijadikan administrator (contoh `-100xxxxxxxxxx`).

### 2.2 Model Enkripsi Client-Side (AES-256-GCM)
- **PIN Pengguna**: 6 digit PIN (atau passphrase) yang dimasukkan pengguna saat setup awal aplikasi. Hash verifikasi PIN (SHA-256 dari PIN + salt global) disimpan di `app_settings` untuk memvalidasi input saat sesi dibuka.
- **Kunci Enkripsi Master**: Diturunkan dari PIN menggunakan PBKDF2-HMAC-SHA256 dengan 10.000 iterasi dan salt acak per file (32 bytes) menghasilkan kunci simetris 256-bit.
- **Enkripsi Chunk**:
  - Ukuran chunk mentah: Maksimal 15.728.640 bytes (15 MB).
  - Setiap chunk mendapatkan IV/nonce acak 12 bytes.
  - Mode enkripsi: AES-GCM menghasilkan ciphertext ditambah 16 bytes authentication tag.
  - Komputasi enkripsi dan dekripsi dijalankan di isolate terpisah melalui Flutter `compute()` agar main thread UI tetap 60fps tanpa lagging.

---

## 3. Skema Basis Data SQLite Lokal (`tgcloud.db`)

### 3.1 Tabel `cloud_files`
Menyimpan metadata file utama yang telah atau sedang diproses.

| Kolom | Tipe | Keterangan |
|---|---|---|
| `id` | INTEGER PRIMARY KEY AUTOINCREMENT | ID lokal unik |
| `nama` | TEXT NOT NULL | Nama file tampilan. Jika duplikat, diubah menjadi `nama (1).ext` |
| `ukuran_bytes` | INTEGER NOT NULL | Ukuran file asli sebelum dienkripsi |
| `mime` | TEXT NOT NULL | MIME type file (misal `video/mp4`, `image/jpeg`) |
| `sha256_original` | TEXT NOT NULL | Hash SHA-256 file asli untuk deduplikasi dan verifikasi download |
| `is_encrypted` | INTEGER NOT NULL DEFAULT 1 | 1 = Terenkripsi AES-GCM, 0 = Plain |
| `salt` | TEXT NOT NULL | Salt hex untuk PBKDF2 file ini |
| `jumlah_chunk` | INTEGER NOT NULL | Total jumlah chunk |
| `dibuat_pada` | TEXT NOT NULL | Waktu pembuatan (ISO-8601) |
| `status` | TEXT NOT NULL | `uploading`, `complete`, `failed` |

### 3.2 Tabel `cloud_chunks`
Menyimpan data potongan chunk untuk mendukung proses resumable dan penghapusan remote.

| Kolom | Tipe | Keterangan |
|---|---|---|
| `id` | INTEGER PRIMARY KEY AUTOINCREMENT | ID chunk |
| `file_id` | INTEGER NOT NULL | Foreign key ke `cloud_files.id` (ON DELETE CASCADE) |
| `chunk_index` | INTEGER NOT NULL | Indeks urutan chunk (0, 1, 2, ... N-1) |
| `ukuran_chunk` | INTEGER NOT NULL | Ukuran chunk terenkripsi (bytes) |
| `tg_file_id` | TEXT | Telegram `file_id` hasil upload |
| `tg_message_id` | INTEGER | Telegram `message_id` pesan dokumen di channel |
| `nonce_hex` | TEXT NOT NULL | Nonce/IV 12 bytes dalam format hex |
| `sha256_chunk` | TEXT NOT NULL | Hash SHA-256 chunk terenkripsi |
| `status` | TEXT NOT NULL | `pending`, `uploading`, `done`, `failed` |

### 3.3 Tabel `app_settings`
Menyimpan konfigurasi aplikasi.

| Kolom | Tipe | Keterangan |
|---|---|---|
| `key` | TEXT PRIMARY KEY | Kunci pengaturan |
| `value` | TEXT NOT NULL | Nilai pengaturan |

Daftar kunci pengaturan:
- `pin_salt`: Salt global untuk verifikasi PIN.
- `pin_hash`: Hash verifikasi PIN.
- `wifi_only`: Boolean (`true`/`false`), transfer hanya aktif jika terhubung ke WiFi.
- `auto_backup_enabled`: Boolean (`true`/`false`).
- `backup_folder_path`: Path folder target cadangan otomatis (default: folder Camera).
- `last_backup_time`: Timestamp ISO-8601 pencadangan terakhir yang berhasil.

---

## 4. Layanan Telegram Storage (`TelegramStorageService`)

### 4.1 Endpoint Bot API
Menggunakan instance `Dio` dengan base URL `https://api.telegram.org/bot<TG_BOT_TOKEN>/`.

1. **`sendDocument`**:
   - Metode: `POST /sendDocument` (multipart/form-data).
   - Form Fields:
     - `chat_id`: Nilai `TG_CHAT_ID`.
     - `document`: MultipartFile dari bytes chunk terenkripsi dengan nama format `<sha256_chunk>.bin`.
     - `caption`: Teks metadata pendek, misal `#tgcloud chunk=<index+1>/<total>`.
   - Response: Ekstrak `result.document.file_id` dan `result.message_id`.

2. **`getFile`**:
   - Metode: `GET /getFile?file_id=<tg_file_id>`.
   - Response: Ekstrak `result.file_path`.
   - Download URL: `https://api.telegram.org/file/bot<TG_BOT_TOKEN>/<result.file_path>`.

3. **`deleteMessage`**:
   - Metode: `POST /deleteMessage`.
   - JSON Body: `{ "chat_id": TG_CHAT_ID, "message_id": tg_message_id }`.
   - Digunakan untuk pembatalan upload di tengah jalan dan penghapusan file permanen dari channel.

### 4.2 Manajemen Kegagalan Jaringan
- Timeout koneksi: 30 detik; Timeout send/receive: 60 detik per chunk.
- Retry otomatis: Maksimal 3 kali dengan exponential backoff (2s, 4s, 8s).
- Rate Limit Telegram (HTTP 429): Interceptor menangkap header `retry_after`, menunggu durasi yang diminta sebelum mengulang request.

---

## 5. Pipeline Transfer

### 5.1 Pipeline Upload
1. Pengguna memilih file melalui `file_picker`.
2. Hitung hash `sha256_original` file asli. Cek ke tabel `cloud_files`: jika file dengan hash sama dan status `complete` sudah ada, tampilkan pemberitahuan deduplikasi dan batalkan upload redundan.
3. Cek nama duplikat: jika nama sudah ada, tambahkan penomoran `nama (1).ext`.
4. Hitung total chunk: `ceil(file_size / 15MB)`.
5. Buat entri di `cloud_files` dengan status `uploading`, buat entri semua chunk di `cloud_chunks` dengan status `pending`.
6. Aktifkan Android Foreground Service dengan notifikasi persisten.
7. Jalankan Worker Pool dengan konkurensi maksimal 2 chunk paralel:
   - Baca potongan 15MB dari disk via `RandomAccessFile`.
   - Enkripsi chunk di `compute()` menggunakan AES-256-GCM.
   - Hitung `sha256_chunk`.
   - Kirim multipart ke Telegram `sendDocument`.
   - Simpan `tg_file_id` dan `tg_message_id`, ubah status chunk ke `done`.
   - Kirim pembaruan progres ke stream UI dan notifikasi foreground.
8. Setelah seluruh chunk berstatus `done`, ubah status `cloud_files` menjadi `complete`.
9. Hentikan Foreground Service dan perbarui daftar file di UI.

### 5.2 Pembatalan Upload
- Jika tombol "Batalkan" ditekan:
  - Batalkan semua request Dio yang sedang aktif menggunakan `CancelToken`.
  - Ambil semua `tg_message_id` chunk yang sudah terlanjur terunggah untuk file tersebut.
  - Panggil `deleteMessage` untuk tiap `tg_message_id` agar channel Telegram tetap bersih.
  - Hapus baris file dan chunk terkait dari database SQLite.
  - Hentikan Foreground Service.

### 5.3 Pipeline Download & Rekonstruksi
1. Pengguna menekan tombol "Download" pada kartu file.
2. Ambil metadata file dan daftar chunk dari SQLite terurut berdasarkan `chunk_index`.
3. Tentukan file output di folder publik Downloads Android (atau cache internal jika izin dibatasi).
4. Buat file output kosong menggunakan `RandomAccessFile` mode tulis biner.
5. Jalankan download chunk secara sequential:
   - Ambil URL unduhan via `getFile`.
   - Download stream chunk terenkripsi.
   - Verifikasi SHA-256 chunk terenkripsi dengan `sha256_chunk` di database. Jika gagal, ulangi download chunk hingga 3 kali.
   - Dekripsi chunk melalui `compute()` AES-256-GCM.
   - Tulis hasil dekripsi langsung ke disk pada posisi offset yang sesuai (`writeFrom`).
   - Perbarui progres download di UI dan notifikasi.
6. Setelah semua chunk tertulis, tutup file.
7. Hitung SHA-256 seluruh file output dan cocokkan dengan `sha256_original`.
   - Jika cocok: download sukses, tampilkan tombol "Buka File".
   - Jika tidak cocok: hapus file korup, laporkan error integritas ke pengguna.
8. Membuka file menggunakan library `open_filex` sesuai MIME type.

---

## 6. Layanan Latar Belakang & Cadangan Otomatis

### 6.1 Android Foreground Service
- Menggunakan `flutter_foreground_task` saat proses upload atau download aktif.
- Menampilkan notifikasi persisten dengan:
  - Judul: "TGCloud — Mengunggah <nama_file>" atau "TGCloud — Mengunduh <nama_file>"
  - Isi teks: "Chunk X dari Y • Z%"
  - Progress bar numerik.
- Mencegah sistem Android membunuh proses saat aplikasi diminimalkan atau layar dimatikan.

### 6.2 Cadangan Otomatis & Manual (`BackupService`)
- **Pencadangan Manual**:
  - Tombol "Cadangkan Sekarang" membuka pemilihan folder (default galeri/DCIM).
  - Pindai semua file gambar dan video.
  - Hitung SHA-256 file lokal dan cocokkan dengan database.
  - Masukkan file baru ke dalam antrean upload.
- **Pencadangan Otomatis (WorkManager)**:
  - Mendaftarkan PeriodicTask di `workmanager` setiap 24 jam (atau interval yang dipilih).
  - Constraints: `NetworkType.unmetered` (hanya WiFi) dan opsional `requiresCharging`.
  - Menjalankan pemindaian folder dan upload file baru secara otomatis di background.
  - Mencatat timestamp cadangan terakhir di `app_settings` (`last_backup_time`).

---

## 7. Desain Antarmuka Pengguna (UI)

### 7.1 Palet Warna & Tipografi
- **Background Utama**: `#121212` (Charcoal gelap)
- **Card & Dialog Surface**: `#1E1E1E` (Abu-abu gelap kontras)
- **Aksen Utama**: `#FF9800` (Amber terang)
- **Aksen Sekunder / Indikator**: `#FFA726` (Amber lembut)
- **Teks Utama**: `#FFFFFF` (Putih terang)
- **Teks Muted**: `#9E9E9E` (Abu-abu sedang)
- **Garis Batas (Divider / Border)**: `#2A2A2A`
- **Status Sukses / Selesai**: `#4CAF50` (Hijau)
- **Status Gagal / Batal**: `#F44336` (Merah)

### 7.2 Struktur Layar
1. **Layar Utama (`HomeScreen`)**:
   - Header ringkasan: Total file dan total kapasitas terpakai (format MB/GB).
   - Search bar realtime: Filter pencarian nama file tanpa tombol submit.
   - List View: Kartu file berisi ikon kategori (Video, Gambar, Dokumen, Arsip), nama file, ukuran, tanggal unggah berformat bahasa Indonesia (`d MMM yyyy, HH:mm`), tombol download, dan menu titik tiga (Hapus File).
   - Floating Action Button (FAB): Tombol amber besar dengan ikon upload untuk membuka pemilih file.
2. **Sheet Progres Upload (`UploadProgressSheet`)**:
   - Tampil saat upload berjalan: Nama file, status chunk ("Mengunggah chunk 2 dari 5"), progress bar amber beranimasi halus, indikator kecepatan, tombol Batal berwarna merah.
3. **Layar Pengaturan & Cadangan (`SettingsScreen`)**:
   - Pengaturan PIN enkripsi (Ubah PIN / Verifikasi PIN).
   - Sakelar "Hanya WiFi".
   - Seksi Cadangan: Status terakhir ("Terakhir dicadangkan: 14 Okt 2026 09:30"), tombol "Cadangkan Sekarang", dan sakelar "Cadangan Otomatis Terjadwal".
   - Tombol "Bersihkan Cache Sementara".

---

## 8. Rencana Pengujian & Kriteria Keberhasilan

1. **Analisis Statis**: `flutter analyze` menghasilkan 0 error dan 0 warning kritis.
2. **Uji Chunking & Kripto**: File 50MB terpecah menjadi 4 chunk (3x 15MB + 1x 5MB), terenkripsi AES-256-GCM, dan berhasil didekripsi menjadi file yang identik (SHA-256 sama persis).
3. **Uji API Telegram**: Upload chunk via `sendDocument` menghasilkan `file_id` dan `message_id` valid di channel Telegram; penghapusan chunk via `deleteMessage` berhasil.
4. **Uji Ketahanan Jaringan**: Simulasi pemutusan koneksi internet di tengah upload chunk memicu retry otomatis hingga 3 kali tanpa merusak urutan metadata.
5. **Uji Foreground**: Upload file 100MB+ tetap berjalan normal saat aplikasi diminimalkan dan membuka aplikasi lain di Android.
6. **Uji Reassembly**: Download file multi-chunk selesai dan file dapat dibuka melalui intent sistem Android.
