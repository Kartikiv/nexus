// messaging_service.dart
import 'dart:convert';
import 'package:stomp_dart_client/stomp_dart_client.dart';

class MessagingService {
  final String username;
  final void Function(Map<String, dynamic>) onMessageReceived;
  late StompClient _client;

  MessagingService({required this.username, required this.onMessageReceived});

  void connect(String jwtToken) {
    print(jwtToken);
    print(username);
    var jwt = jwtToken;
    _client = StompClient(
      config: StompConfig(
        url: 'ws://138.2.224.56:8888/messaging-server/ws?name=${Uri.encodeComponent(username)}',
        stompConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        webSocketConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        onConnect: _onConnect,
        reconnectDelay: const Duration(seconds: 5),
      ),
    );

    _client.activate();
  }

  void _onConnect(StompFrame frame) {
    _client.subscribe(
      destination: '/user/$username/queue/messages',
      callback: (frame) {
        final data = jsonDecode(frame.body!);
        print("recieved:     _______________>");
        print(data);
        onMessageReceived(data);
      },
    );
  }

  void sendMessage(String recipient, String text) {
    print(text);
    print(recipient);
    final message = jsonEncode({
      "sender": username,
      "recipient": recipient,
      "filename": "dd",
      "content": text,
    });
    _client.send(destination: '/app/chat.sendPrivate', body: message);
  }

  void dispose() {
    _client.deactivate();
  }
}