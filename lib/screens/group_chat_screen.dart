import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:stomp_dart_client/stomp_dart_client.dart';


class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String username;
  final String jwt;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.username,
    required this.jwt,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late StompClient _client;

  @override
  void initState() {
    super.initState();
    _connectToWebSocket();
    _loadInitialMessages();
  }

  Future<void> _loadInitialMessages() async {
    final uri = Uri.parse('http://138.2.224.56:8888/messaging-server/api/groups/user/${widget.username}');
    final response = await http.get(uri, headers: {
      'Authorization': 'Bearer ${widget.jwt}',
      'Content-Type': 'application/json'
    });
    print(response.body);

    if (response.statusCode == 200) {
      final List<dynamic> history = jsonDecode(response.body);
      setState(() => _messages.addAll(history.cast<Map<String, dynamic>>()));
    }
  }

  void _connectToWebSocket() {
    _client = StompClient(
      config: StompConfig(
        url: 'ws://138.2.224.56:8888/messaging-server/ws?name=${Uri.encodeComponent(widget.groupId)}',
        stompConnectHeaders: {'Authorization': 'Bearer ${widget.jwt}'},
        webSocketConnectHeaders: {'Authorization': 'Bearer ${widget.jwt}'},
        onConnect: _onConnect,
        onWebSocketError: (e) => print('WebSocket error: $e'),
        onStompError: (f) => print('STOMP error: ${f.body}'),
        onDisconnect: (_) => print('Disconnected from WebSocket'),
        reconnectDelay: const Duration(seconds: 5),
      ),
    );
    _client.activate();
  }

  void _onConnect(StompFrame frame) {
    _client.subscribe(
      destination: '/topic/group.${widget.groupId}',
      callback: (frame) {
        final data = jsonDecode(frame.body!);
        if (data['sender'] != widget.username) {
          setState(() => _messages.add(data));
          _scrollToBottom();
        }
      },
    );
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final message = {
      'groupId': widget.groupId,
      'sender': widget.username,
      'content': text,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _client.send(
      destination: '/app/group.send',
      body: jsonEncode(message),
    );

    setState(() => _messages.add(message));
    _controller.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _client.deactivate();
    super.dispose();
  }

  Widget _buildMessage(Map<String, dynamic> msg) {
    final isMe = msg['sender'] == widget.username;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? Colors.blue[100] : Colors.grey[300],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isMe ? "You" : msg['sender'],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(msg['content'] ?? ''),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.groupName)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              itemBuilder: (_, i) => _buildMessage(_messages[i]),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: "Type a message...",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}
