class CloudFile {
  final int? id;
  final String nama;
  final int ukuranBytes;
  final String mime;
  final String sha256Original;
  final int isEncrypted;
  final String salt;
  final int jumlahChunk;
  final String dibuatPada;
  final String status;

  CloudFile({
    this.id,
    required this.nama,
    required this.ukuranBytes,
    required this.mime,
    required this.sha256Original,
    this.isEncrypted = 1,
    required this.salt,
    required this.jumlahChunk,
    required this.dibuatPada,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'nama': nama,
        'ukuran_bytes': ukuranBytes,
        'mime': mime,
        'sha256_original': sha256Original,
        'is_encrypted': isEncrypted,
        'salt': salt,
        'jumlah_chunk': jumlahChunk,
        'dibuat_pada': dibuatPada,
        'status': status,
      };

  factory CloudFile.fromMap(Map<String, dynamic> map) => CloudFile(
        id: map['id'] as int?,
        nama: map['nama'] as String,
        ukuranBytes: map['ukuran_bytes'] as int,
        mime: map['mime'] as String,
        sha256Original: map['sha256_original'] as String,
        isEncrypted: map['is_encrypted'] as int? ?? 1,
        salt: map['salt'] as String,
        jumlahChunk: map['jumlah_chunk'] as int,
        dibuatPada: map['dibuat_pada'] as String,
        status: map['status'] as String,
      );
}
