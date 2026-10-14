class AppConfig {
  static const String botToken = String.fromEnvironment('TG_BOT_TOKEN', defaultValue: '');
  static const String chatId = String.fromEnvironment('TG_CHAT_ID', defaultValue: '');
  static const int chunkSizeBytes = 15 * 1024 * 1024; // 15MB

  static bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;
}
