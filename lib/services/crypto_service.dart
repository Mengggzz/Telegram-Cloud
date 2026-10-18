import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

/// Dijalankan di isolate latar via compute(): baca file secara streaming
/// (memori konstan) lalu kembalikan hex digest SHA-256.
/// Harus fungsi top-level agar bisa dikirim ke isolate.
Future<String> _hashFileBackground(String filePath) async {
  final digest = await sha256.bind(File(filePath).openRead()).first;
  return digest.toString();
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

  /// Hitung SHA-256 sebuah file langsung dari disk.
  /// Dijalankan di isolate latar + streaming, sehingga UI tidak freeze
  /// dan memori tetap kecil walau file ratusan MB/GB.
  /// (Menggantikan pola readAsBytes + calculateSha256 untuk file besar.)
  static Future<String> calculateFileSha256(String filePath) {
    return compute(_hashFileBackground, filePath);
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
