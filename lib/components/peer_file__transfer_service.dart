import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

import '../screens/P2P_file_transfer.dart';



class ChatScreen extends StatefulWidget {
  final String username;
  final String recipient;

  const ChatScreen({
    super.key,
    required this.username,
    required this.recipient,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late StompClient stompClient;
  late StompClient fileSignalClient;
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;

  List<Map<String, dynamic>> get messages => _messages;

  @override
  void initState() {
    super.initState();
    _initializeWebSocket();
  }

  void _initializeWebSocket() {
    var jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJrYXJ0aWtpdiIsImlhdCI6MTc0NTUyOTUxMywiZXhwIjoxNzQ1NjM3NTEzfQ.K-jwn1qRmUbVh0BadI-U7l88E5qCk_ibW4KJwbYl_24';
    stompClient = StompClient(
      config: StompConfig(
        url: 'ws://192.168.1.132:8888/messaging-server/ws?name=${Uri.encodeComponent(widget.username)}',
        stompConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        webSocketConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        onConnect: _onConnect,
        onWebSocketError: (error) => _showError('WebSocket Error: $error'),
        onStompError: (frame) => _showError('STOMP Error: ${frame.body}'),
        onDisconnect: (_) {
          setState(() => _isConnected = false);
          _showError('Disconnected from server');
        },
        reconnectDelay: const Duration(seconds: 5),
      ),
    );

    stompClient.activate();
  }
  void _initializeFileSignalSocket(){
    var jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJrYXJ0aWtpdiIsImlhdCI6MTc0NTUyOTUxMywiZXhwIjoxNzQ1NjM3NTEzfQ.K-jwn1qRmUbVh0BadI-U7l88E5qCk_ibW4KJwbYl_24';
    stompClient = StompClient(
      config: StompConfig(
        url: 'ws://192.168.1.132:8888/file-server/ws?name=${Uri.encodeComponent(widget.username)}',
        stompConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        webSocketConnectHeaders: {
          'Authorization': 'Bearer $jwt',
        },
        onConnect: _onConnect,
        onWebSocketError: (error) => _showError('WebSocket Error: $error'),
        onStompError: (frame) => _showError('STOMP Error: ${frame.body}'),
        onDisconnect: (_) {
          setState(() => _isConnected = false);
          _showError('Disconnected from server');
        },
        reconnectDelay: const Duration(seconds: 5),
      ),
    );

    stompClient.activate();
  }


  void _onConnect(StompFrame frame) {
    setState(() => _isConnected = true);

    stompClient.subscribe(
      destination: '/user/${widget.username}/queue/messages',
      callback: (frame) {
        if (frame.body != null) {
          try {
            final data = jsonDecode(frame.body!);
            _addMessage(
              sender: 'other',
              text: data['content'],
              isFile: data['fileData'] != null,
              filename: data['filename'],
              fileData: data['fileData'],
              mimeType: data['mimeType'],
              timestamp: DateTime.now(),
            );
          } catch (e) {
            _showError('Failed to parse message: $e');
          }
        }
      },
    );
  }

  void _addMessage({
    required String sender,
    String? text,
    bool isFile = false,
    String? filename,
    String? fileData,
    String? mimeType,
    DateTime? timestamp,
  }) {
    setState(() {
      _messages.add({
        "sender": sender,
        "text": text,
        "isFile": isFile,
        "filename": filename,
        "fileData": fileData,
        "mimeType": mimeType,
        "timestamp": timestamp ?? DateTime.now(),
      });
    });

    // Scroll to bottom when new message arrives
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

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final payload = {
      "sender": widget.username,
      "recipient": widget.recipient,
      "filename": "dd",
      "content": content,
    };

    try {
      stompClient.send(
        destination: '/app/chat.sendPrivate',
        body: jsonEncode(payload),
      );

      _addMessage(
        sender: 'me',
        text: content,
      );

      _messageController.clear();
    } catch (e) {
      _showError('Failed to send message: $e');
      print(e);
    }
  }
  void _share(){
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => P2PFileTransferScreen(username: widget.username, recipient: widget.recipient,),
      ),
    );
  }
  Future<void> _pickAndSendFile() async {
    try {
      print("Picking file...");
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.single.bytes == null) {
        print("No file selected or file data is null.");
        return;
      }
      final file = result.files.single;
      print("File selected: ${file.name}, size: ${file.size}");
      final base64File = base64Encode(file.bytes!);
      final mimeType = lookupMimeType(file.name) ?? "application/octet-stream";

      if (file.size > 10 * 1024 * 1024) {
        _showError('File too large (max 10MB)');
        return;
      }

      final filePayload = {
        "sender": widget.username,
        "recipient": widget.recipient,
        "filename": file.name,
        "fileData": base64File,
        "mimeType": mimeType,
      };

      print("Sending file payload...");
      stompClient.send(
        destination: '/app/chat.sendPrivate',
        body: jsonEncode(filePayload),
      );

      _addMessage(
        sender: 'me',
        isFile: true,
        filename: file.name,
        fileData: base64File,
        mimeType: mimeType,
      );
      print("File message sent.");
    } catch (e) {
      _showError('Failed to send file: $e');
      print("Error sending file: $e");
    }
  }


  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> message) {
    final isMe = message['sender'] == 'me';
    final alignment = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isMe ? Colors.blue[100] : Colors.grey[300];
    final timestamp = message['timestamp'] as DateTime?;

    Widget content;

    if (message['isFile'] == true) {
      final mimeType = message['mimeType'] ?? '';
      if (mimeType.startsWith('image/')) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                base64Decode(message['fileData']),
                height: 200,
                width: 200,
                fit: BoxFit.cover,
              ),
            ),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _formatTime(timestamp),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
          ],
        );
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("📎 ${message['filename']}"),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _formatTime(timestamp),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
          ],
        );
      }
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message['text'] ?? ""),
          if (timestamp != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _formatTime(timestamp),
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
        ],
      );
    }

    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: content,
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    return '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    stompClient.deactivate();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text("Chat with ${widget.recipient}"),
            const SizedBox(width: 8),
            Icon(
              _isConnected ? Icons.circle : Icons.circle_outlined,
              color: _isConnected ? Colors.green : Colors.red,
              size: 12,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              itemBuilder: (_, index) => _buildMessageBubble(_messages[index]),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _share,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}