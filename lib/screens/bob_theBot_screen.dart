import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../service/bob_service.dart';

class BobChatScreen extends StatefulWidget {
  final String username;

  const BobChatScreen({super.key, required this.username});

  @override
  State<BobChatScreen> createState() => _BobChatScreenState();
}

class _BobChatScreenState extends State<BobChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  late BobService _bobService;

  @override
  void initState() {
    super.initState();
    _bobService = BobService(username: widget.username);
    _loadMessages();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('chat_${widget.username}_bob');
    if (raw != null) {
      setState(() {
        _messages.addAll(raw.map((e) => jsonDecode(e) as Map<String, dynamic>));
      });
    }
  }

  Future<void> _saveMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _messages.map((m) => jsonEncode(m)).toList();
    await prefs.setStringList('chat_${widget.username}_bob', encoded);
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final userMsg = {'sender': 'me', 'content': text, 'timestamp': DateTime.now().toIso8601String()};
    setState(() => _messages.add(userMsg));
    _controller.clear();
    _scrollToBottom();
    await _saveMessages();

    final replyText = await _bobService.generateReply(text);
    final botReply = {'sender': 'bob', 'content': replyText, 'timestamp': DateTime.now().toIso8601String()};

    setState(() => _messages.add(botReply));
    _scrollToBottom();
    await _saveMessages();
  }

  Widget _buildBubble(Map<String, dynamic> message) {
    final isUser = message['sender'] == 'me';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Colors.blue[100] : Colors.grey[300],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message['content'] ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat with Bob the Bot')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              itemBuilder: (_, index) => _buildBubble(_messages[index]),
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
                      hintText: "Ask Bob something...",
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

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
