// messaging_service.dart
import 'dart:convert';
import 'package:stomp_dart_client/stomp_dart_client.dart';
class MessagingService {
  final String username;
  final String recipient;
  final void Function(Map<String, dynamic>) onMessageReceived;
  late StompClient _client;

  MessagingService({
    required this.username,
    required this.onMessageReceived,
    required this.recipient,
  });

  void connect(String jwtToken) {
    _client = StompClient(
      config: StompConfig(
        url: 'ws://138.2.224.56:8888/messaging-server/ws?name=${Uri.encodeComponent(username)}',
        stompConnectHeaders: {
          'Authorization': 'Bearer $jwtToken',
        },
        webSocketConnectHeaders: {
          'Authorization': 'Bearer $jwtToken',
        },
        onConnect: _onConnect,
        reconnectDelay: const Duration(seconds: 5),
      ),
    );

    _client.activate();
  }

  void _onConnect(StompFrame frame) {
    final subscriptionKey = '$username$recipient';
    print('Subscribing to: /user/$subscriptionKey/queue/messages');

    _client.subscribe(
      destination: '/user/$subscriptionKey/queue/messages',
      callback: (frame) {
        final data = jsonDecode(frame.body!);
        print("Received: $data");
        onMessageReceived(data);
      },
    );
  }

  void sendMessage(String text) {
    final recipientKey = '$recipient$username';

    final message = jsonEncode({
      "sender": username,
      "recipient": recipientKey,
      "filename": "dd",
      "content": text,
    });

    print("Sending to /app/chat.sendPrivate: $message");
    _client.send(destination: '/app/chat.sendPrivate', body: message);
  }

  void dispose() {
    _client.deactivate();
  }
}
