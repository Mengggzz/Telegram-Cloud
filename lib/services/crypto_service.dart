import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<void> _hashFileStreamWorker(List<dynamic> args) async {
  final filePath = args[0] as String;
  final sendPort = args[1] as SendPort;
  final totalBytes = args[2] as int;

  try {
    final file = File(filePath);
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);

    int bytesRead = 0;
    int lastReported = 0;
    final reportInterval = max(1024 * 1024, totalBytes ~/ 100);

    await for (final chunk in file.openRead()) {
      input.add(chunk);
      bytesRead += chunk.length;

      if (bytesRead - lastReported >= reportInterval || bytesRead >= totalBytes) {
        lastReported = bytesRead;
        sendPort.send([bytesRead, totalBytes]);
      }
    }

    input.close();
    final hashHex = sink.value?.toString() ?? '';
    sendPort.send([bytesRead, totalBytes, hashHex]);
  } catch (e) {
    sendPort.send('ERROR:$e');
  }
}

class HashProgress {
  final int bytesRead;
  final int totalBytes;
  final String? hash;

  double get fraction => totalBytes > 0 ? (bytesRead / totalBytes).clamp(0.0, 1.0) : 0.0;
  int get percentage => (fraction * 100).toInt();

  HashProgress({
    required this.bytesRead,
    required this.totalBytes,
    this.hash,
  });
}

Uint8List _encryptChunkBackground(List<dynamic> args) {
  final chunkBytes = args[0] as List<int>;
  final keyBytes = args[1] as List<int>;
  final nonceHex = args[2] as String;
  return Uint8List.fromList(CryptoService.encryptChunk(chunkBytes, keyBytes, nonceHex));
}

class ChunkProcessResult {
  final Uint8List bytes;
  final String sha256;
  ChunkProcessResult({required this.bytes, required this.sha256});
}

ChunkProcessResult _encryptAndHashChunkBackground(List<dynamic> args) {
  final chunkBytes = args[0] as List<int>;
  final keyBytes = args[1] as List<int>;
  final nonceHex = args[2] as String;
  final encryptedBytes = Uint8List.fromList(CryptoService.encryptChunk(chunkBytes, keyBytes, nonceHex));
  final hash = CryptoService.calculateSha256(encryptedBytes);
  return ChunkProcessResult(bytes: encryptedBytes, sha256: hash);
}

List<int> _verifyAndDecryptChunkBackground(List<dynamic> args) {
  final encryptedBytes = args[0] as List<int>;
  final keyBytes = args[1] as List<int>;
  final nonceHex = args[2] as String;
  final expectedHash = args[3] as String;

  final actualHash = CryptoService.calculateSha256(encryptedBytes);
  if (actualHash != expectedHash) {
    throw Exception('Integritas chunk rusak! Hash tidak cocok.');
  }
  return CryptoService.decryptChunk(encryptedBytes, keyBytes, nonceHex);
}

class CryptoService {
  static final Random _secureRandom = Random.secure();

  static String generateSalt([int length = 32]) {
    final values = List<int>.generate(length, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String generateNonce([int length = 12]) {
    final values = List<int>.generate(length, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  static List<int> deriveKey(String pin, String saltHex, {int iterations = 10000}) {
    final saltBytes = _hexToBytes(saltHex);
    final hmac = Hmac(sha256, saltBytes);
    var derived = hmac.convert(pin.codeUnits).bytes;
    for (int i = 1; i < iterations; i++) {
      derived = hmac.convert(derived).bytes;
    }
    return derived;
  }

  static List<int> encryptChunk(List<int> chunkBytes, List<int> keyBytes, String nonceHex) {
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(_hexToBytes(nonceHex));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(chunkBytes, iv: iv);
    return encrypted.bytes;
  }

  static List<int> decryptChunk(List<int> encryptedBytes, List<int> keyBytes, String nonceHex) {
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(_hexToBytes(nonceHex));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final decrypted = encrypter.decryptBytes(enc.Encrypted(Uint8List.fromList(encryptedBytes)), iv: iv);
    return decrypted;
  }

  static String calculateSha256(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  /// Hitung SHA-256 sebuah file langsung dari disk dengan streaming progress.
  /// Dijalankan di isolate latar agar UI tidak freeze dan memori konstan.
  static Stream<HashProgress> calculateFileSha256Progress(String filePath) async* {
    final file = File(filePath);
    final totalBytes = await file.length();
    if (totalBytes == 0) {
      yield HashProgress(bytesRead: 0, totalBytes: 0, hash: sha256.convert([]).toString());
      return;
    }

    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(_hashFileStreamWorker, [filePath, receivePort.sendPort, totalBytes]);

    try {
      await for (final msg in receivePort) {
        if (msg is List) {
          final bytesRead = msg[0] as int;
          final total = msg[1] as int;
          final hash = msg.length > 2 ? msg[2] as String? : null;
          yield HashProgress(bytesRead: bytesRead, totalBytes: total, hash: hash);
          if (hash != null) break;
        } else if (msg is String && msg.startsWith('ERROR:')) {
          throw Exception(msg.substring(6));
        }
      }
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Hitung SHA-256 sebuah file langsung dari disk.
  /// Dijalankan di isolate latar + streaming.
  static Future<String> calculateFileSha256(String filePath) async {
    await for (final p in calculateFileSha256Progress(filePath)) {
      if (p.hash != null) return p.hash!;
    }
    throw Exception('Gagal menghitung hash file: $filePath');
  }

  /// Enkripsi chunk di isolate latar agar UI tidak freeze.
  static Future<enc.Encrypted> encryptChunkIsolate(
    List<int> chunkBytes,
    List<int> keyBytes,
    String nonceHex,
  ) async {
    final bytes = await compute(_encryptChunkBackground, [chunkBytes, keyBytes, nonceHex]);
    return enc.Encrypted(bytes);
  }

  /// Enkripsi chunk sekaligus hitung SHA-256 di isolate latar agar UI tidak freeze.
  static Future<ChunkProcessResult> encryptAndHashChunkIsolate(
    List<int> chunkBytes,
    List<int> keyBytes,
    String nonceHex,
  ) {
    return compute(_encryptAndHashChunkBackground, [chunkBytes, keyBytes, nonceHex]);
  }

  /// Verifikasi integritas hash dan dekripsi chunk di isolate latar.
  static Future<List<int>> verifyAndDecryptChunkIsolate(
    List<int> encryptedBytes,
    List<int> keyBytes,
    String nonceHex,
    String expectedHash,
  ) {
    return compute(_verifyAndDecryptChunkBackground, [
      encryptedBytes,
      keyBytes,
      nonceHex,
      expectedHash,
    ]);
  }
}
