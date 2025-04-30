// signaling_service.dart
import 'dart:convert';
import 'package:stomp_dart_client/stomp_dart_client.dart';

class SignalingService {
  final String username;
  final String recipient;
  final void Function(Map<String, dynamic>) onSignalReceived;
  late StompClient _client;

  SignalingService({
    required this.username,
    required this.recipient,
    required this.onSignalReceived,
  });

  void connect(String jwtToken) {
    var jwt = jwtToken;
    print(jwt);
    _client = StompClient(
      config: StompConfig(
        url: 'ws://138.2.224.56:8888/file-server/ws?name=${Uri.encodeComponent(username)}',
        onWebSocketError: (error) => print('Signaling Error: $error'),
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
      destination: '/user/$username/queue/signal',
      callback: (frame) {
        final data = jsonDecode(frame.body!);
        print("Recieved Data________________________________________________->");
        print(data);
        onSignalReceived(data);
      },
    );
  }

  void sendSignal(Map<String, dynamic> data) {
    print ("sent ------------------>");
    print(data);
    _client.send(destination: '/app/signal.send', body: jsonEncode(data));
  }

  void dispose() {
    _client.deactivate();
  }
}
