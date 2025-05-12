import 'dart:convert';

import 'package:crypto/crypto.dart';
class AppConfig {
  static const String baseUrl = 'http://138.2.224.56:8888'; // change this
  static const String iceServerUrl = 'https://kartikiv.metered.live/api/v1/turn/credentials?apiKey=f0b07562e76356b1030637b562cbb1c6f4cc';
  String generateGroupHash(List<String> usernames) {
    usernames.sort();
    final joined = usernames.join(',');
    return sha256.convert(utf8.encode(joined)).toString();
  }
}