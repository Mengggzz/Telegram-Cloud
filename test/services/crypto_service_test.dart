import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/crypto_service.dart';

void main() {
  group('CryptoService', () {
    const pin = '123456';

    test('generateSalt returns 64-char hex string (32 bytes)', () {
      final salt = CryptoService.generateSalt();
      expect(salt.length, equals(64));
    });

    test('generateNonce returns 24-char hex string (12 bytes)', () {
      final nonce = CryptoService.generateNonce();
      expect(nonce.length, equals(24));
    });

    test('deriveKey returns consistent 32-byte key for same PIN and salt', () {
      final salt = CryptoService.generateSalt();
      final key1 = CryptoService.deriveKey(pin, salt);
      final key2 = CryptoService.deriveKey(pin, salt);
      expect(key1, equals(key2));
      expect(key1.length, equals(32));
    });

    test('encryptChunk and decryptChunk restores original data', () {
      final salt = CryptoService.generateSalt();
      final key = CryptoService.deriveKey(pin, salt);
      final nonce = CryptoService.generateNonce();
      final original = utf8.encode('Hello Telegram Cloud AES-256-GCM Test!');

      final encrypted = CryptoService.encryptChunk(original, key, nonce);
      expect(encrypted, isNot(equals(original)));
      // GCM tag is 16 bytes appended
      expect(encrypted.length, equals(original.length + 16));

      final decrypted = CryptoService.decryptChunk(encrypted, key, nonce);
      expect(decrypted, equals(original));
    });

    test('calculateSha256 returns valid 64-char hex hash', () {
      final data = utf8.encode('test-hash-data');
      final hash = CryptoService.calculateSha256(data);
      expect(hash.length, equals(64));
    });

    test('encryptChunkIsolate encrypts in isolate and decrypts correctly', () async {
      final salt = CryptoService.generateSalt();
      final key = CryptoService.deriveKey(pin, salt);
      final nonce = CryptoService.generateNonce();
      final original = utf8.encode('Testing encryptChunkIsolate in isolate!');

      final enc = await CryptoService.encryptChunkIsolate(original, key, nonce);
      expect(enc.bytes, isNot(equals(original)));
      expect(enc.bytes.length, equals(original.length + 16));

      final decrypted = CryptoService.decryptChunk(enc.bytes, key, nonce);
      expect(decrypted, equals(original));
    });
  });
}
