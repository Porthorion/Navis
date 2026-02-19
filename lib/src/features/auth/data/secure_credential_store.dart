import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecureCredentialStore {
  Future<void> savePassword(String password);
  Future<String?> readPassword();
  Future<void> clearPassword();
}

class FlutterSecureCredentialStore implements SecureCredentialStore {
  const FlutterSecureCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _passwordKey = 'navis.auth.active_server.password';

  final FlutterSecureStorage _storage;

  @override
  Future<void> savePassword(String password) {
    return _storage.write(key: _passwordKey, value: password);
  }

  @override
  Future<String?> readPassword() {
    return _storage.read(key: _passwordKey);
  }

  @override
  Future<void> clearPassword() {
    return _storage.delete(key: _passwordKey);
  }
}
