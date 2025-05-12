import 'dart:convert';
import 'dart:io';
import 'package:nexus/service/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BobService {
  final String username;
  final Map<String, String> _nameCache = {};

  BobService({required this.username});

  Future<String> generateReply(String prompt) async {
    final prefs = await SharedPreferences.getInstance();
    final jwt = prefs.getString('auth_token');
    List<String> allChats = [];
     Iterable<String> keys = prefs.getKeys();

    print("📦 SharedPreferences Dump:");
    for (final key in keys) {
      final value = prefs.get(key);
      print("🔑 $key = $value");
    }

  keys = prefs.getKeys().where((key) =>
    key.startsWith('chat_${username}_') && !key.contains('bob'));

    for (final key in keys) {
      final messages = prefs.getStringList(key);
      if (messages != null) {
        final parts = key.split('_');
        final senderId = parts[1];
        final recipientId = parts[2];
        final contactId = senderId == username ? recipientId : senderId;

        final contactName = await _getName(contactId, jwt!);
        final conversation = <String>[];

        for (final e in messages) {
          final msg = jsonDecode(e) as Map<String, dynamic>;
          if (msg['content'] != null && msg['sender'] != null) {
            final sender = msg['sender'].toString();
            final name = (sender == 'me' || sender == username)
                ? 'Me'
                : await _getName(sender, jwt);
            conversation.add("$name: ${msg['content']}");
          }
        }

        allChats.add("Conversation with $contactName:\n${conversation.join(";\n")}\n");
      }
    }
    final contextText = allChats.join("\n---\n");
    final fullPrompt = '''
You are Bob the Bot, a helpful assistant.
The user says: "$prompt"

Here are their recent conversations with others:
$contextText

Please generate a smart, friendly reply.
''';

    return await _callOpenAI(fullPrompt);
  }

  Future<String> _callOpenAI(String prompt) async {
    const apiKey = '';
    final url = Uri.parse("https://api.openai.com/v1/chat/completions");

    final request = await HttpClient().postUrl(url);
    request.headers.set(HttpHeaders.contentTypeHeader, "application/json");
    request.headers.set(HttpHeaders.authorizationHeader, "Bearer $apiKey");
    request.write(jsonEncode({
      "model": "gpt-4.1-mini",
      "messages": [
        {
          "role": "system",
          "content": "You are Bob the Bot, a helpful AI assistant."
        },
        {"role": "user", "content": prompt}
      ]
    }));
    print("🔍 OpenAI raw : $prompt");

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    try {
      final data = jsonDecode(body);
      final choices = data['choices'];
      if (choices != null && choices.isNotEmpty) {
        return choices[0]['message']['content'] ??
            "I'm not sure how to respond.";
      } else if (data['error'] != null) {
        return "❌ OpenAI API error: ${data['error']['message']}";
      } else {
        return "❌ Unexpected response from OpenAI.";
      }
    } catch (e) {
      return "❌ Failed to parse OpenAI response: $e";
    }
  }
  Future<String> _getName(String userId, String jwt) async {
    if (_nameCache.containsKey(userId)) return _nameCache[userId]!;
    final info = await ApiService.getRegisteredUser(userId, jwt);
    final name = info != null ? info['firstName'] ?? userId : userId;
    _nameCache[userId] = name;
    return name;
  }
}
