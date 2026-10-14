class CloudChunk {
  final int? id;
  final int fileId;
  final int chunkIndex;
  final int ukuranChunk;
  final String? tgFileId;
  final int? tgMessageId;
  final String nonceHex;
  final String sha256Chunk;
  final String status;

  CloudChunk({
    this.id,
    required this.fileId,
    required this.chunkIndex,
    required this.ukuranChunk,
    this.tgFileId,
    this.tgMessageId,
    required this.nonceHex,
    required this.sha256Chunk,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'file_id': fileId,
        'chunk_index': chunkIndex,
        'ukuran_chunk': ukuranChunk,
        'tg_file_id': tgFileId,
        'tg_message_id': tgMessageId,
        'nonce_hex': nonceHex,
        'sha256_chunk': sha256Chunk,
        'status': status,
      };

  factory CloudChunk.fromMap(Map<String, dynamic> map) => CloudChunk(
        id: map['id'] as int?,
        fileId: map['file_id'] as int,
        chunkIndex: map['chunk_index'] as int,
        ukuranChunk: map['ukuran_chunk'] as int,
        tgFileId: map['tg_file_id'] as String?,
        tgMessageId: map['tg_message_id'] as int?,
        nonceHex: map['nonce_hex'] as String,
        sha256Chunk: map['sha256_chunk'] as String,
        status: map['status'] as String,
      );
}
