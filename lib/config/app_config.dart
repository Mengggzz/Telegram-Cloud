class AppConfig {
  static const String botToken = String.fromEnvironment('TG_BOT_TOKEN', defaultValue: '');
  static const String chatId = String.fromEnvironment('TG_CHAT_ID', defaultValue: '');
  static const int chunkSizeBytes = 15 * 1024 * 1024; // 15MB

  /// Jumlah worker upload paralel. Throttle Telegram itu per koneksi,
  /// jadi worker lebih banyak = throughput lebih baik (batas wajar: 4).
  static const int maxUploadWorkers = 4;

  static bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;
}
