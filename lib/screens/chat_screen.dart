import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../components/messaging_service.dart';
import '../components/peer_connection_service.dart';
import '../components/signaling_service.dart';
import 'package:mime/mime.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../components/video_preview_widget.dart';

class ChatScreen extends StatefulWidget {
  final String username;
  final String recipient;

  const ChatScreen({super.key, required this.username, required this.recipient});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late MessagingService _messagingService;
  late SignalingService _signalingService;
  PeerConnectionService? _peerConnectionService;

  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late SharedPreferences _prefs;

  late final String? jwt;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadStoredMessages();

    jwt = prefs.getString('auth_token');

    _messagingService = MessagingService(
      username: widget.username,
      onMessageReceived: (msg) async {
        setState(() => _messages.add(msg));
        await _saveMessages();
      },

    );

    _signalingService = SignalingService(
      username: widget.username,
      recipient: widget.recipient,
      onSignalReceived: (data) async {
        if (data['type'] == 'offer') {
          _peerConnectionService = PeerConnectionService(
            username: widget.username,
            recipient: widget.recipient,
            signalingService: _signalingService,
          )..onFileReceived = (filePath, mimeType) async {
            final file = File(filePath);
            final fileName = file.uri.pathSegments.last;

            final msg = {
              'sender': 'them',
              'isFile': true,
              'filePath': filePath,
              'mimeType': mimeType,
              'filename': fileName,
              'timestamp': DateTime.now(),
            };

            setState(() => _messages.add(msg));
            await _saveMessages();
          };

          await _peerConnectionService!.initialize(asInitiator: false);
        }

        await _peerConnectionService?.handleSignal(data);
      },
    );


    _messagingService.connect(jwt!);
    _signalingService.connect(jwt!);
  }
  Future<void> _loadStoredMessages() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getStringList('chat_${widget.username}_${widget.recipient}');
    if (raw != null) {
      setState(() {
        _messages = raw.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
      });
    }
  }

  Future<void> _saveMessages() async {

    final List<String> jsonList = _messages.map((msg) {
      final copy = Map<String, dynamic>.from(msg);
      if (copy['timestamp'] is DateTime) {
        copy['timestamp'] = (copy['timestamp'] as DateTime).toIso8601String();
      }
      return jsonEncode(copy);
    }).toList();

    await _prefs.setStringList('chat_${widget.username}_${widget.recipient}', jsonList);


  }

  String _inferFileName(String mimeType) {
    final extension = {
      'video/mp4': '.mp4',
      'image/jpeg': '.jpg',
      'image/png': '.png',
      'image/gif': '.gif',
      'application/pdf': '.pdf',
      'text/plain': '.txt',
      'application/msword': '.doc',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
    }[mimeType] ?? '.bin';

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'received_file_$timestamp$extension';
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final msg = {'sender': 'me', 'content': text, 'timestamp': DateTime.now()};
    _messagingService.sendMessage(widget.recipient, text);
    setState(() => _messages.add(msg));
    await _saveMessages();
    _messageController.clear();
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles(withReadStream: false);
    if (result == null || result.files.single.path == null) return;

    final filePath = result.files.single.path!;
    final fileName = result.files.single.name;
    final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';

    if (_peerConnectionService == null) {
      _peerConnectionService = PeerConnectionService(
        username: widget.username,
        recipient: widget.recipient,
        signalingService: _signalingService,
      )..onFileReceived = (filePath, mimeType) async {
        final file = File(filePath);
        final filename = file.uri.pathSegments.last;

        final msg = {
          'sender': 'them',
          'isFile': true,
          'filePath': filePath,
          'mimeType': mimeType,
          'filename': filename,
          'timestamp': DateTime.now(),
        };

        setState(() => _messages.add(msg));
        await _saveMessages();
      };

      await _peerConnectionService!.initialize(asInitiator: true);
    }

    await _peerConnectionService!.sendFileFromPath(
      filePath,
      mimeType: mimeType,
      fileName: fileName,
    );




    final sentMsg = {
      'sender': 'me',
      'isFile': true,
      'filePath': filePath,
      'mimeType': mimeType,
      'filename': fileName,
      'timestamp': DateTime.now(),
    };


    setState(() => _messages.add(sentMsg));
    await _saveMessages();
  }


  Future<void> _saveFile(Uint8List bytes, String filename) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Saved to ${file.path}")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to save file")),
      );
    }
  }

  Widget _buildMessageBubble(Map<String, dynamic> message) {
    final isMe = message['sender'] == 'me';
    final alignment = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isMe ? Colors.blue[100] : Colors.grey[300];
    final timestamp = message['timestamp'] is String
        ? DateTime.tryParse(message['timestamp'])
        : message['timestamp'] as DateTime?;

    Widget content;

    if (message['isFile'] == true) {
      final mimeType = message['mimeType'] ?? '';
      final filename = message['filename'] ?? 'file.bin';
      final filePath = message['filePath'];
      final file = File(filePath);

      if (!file.existsSync()) {
        content = Text("File not found");
      } else if (mimeType.startsWith('image/')) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(file, height: 200, width: 200, fit: BoxFit.cover),
            ),
            TextButton.icon(
              icon: const Icon(Icons.download),
              label: const Text("Save"),
              onPressed: () async {
                final bytes = await file.readAsBytes();
                _saveFile(bytes, filename);
              },
            ),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_formatTime(timestamp), style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ),
          ],
        );
      } else if (mimeType.startsWith('video/')) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VideoPreviewWidget(videoBytes: file.readAsBytesSync(), fileName: filename),
            TextButton.icon(
              icon: const Icon(Icons.download),
              label: const Text("Save"),
              onPressed: () async {
                final bytes = await file.readAsBytes();
                _saveFile(bytes, filename);
              },
            ),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_formatTime(timestamp), style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ),
          ],
        );
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(filename),
            TextButton.icon(
              icon: const Icon(Icons.download),
              label: const Text("Save"),
              onPressed: () async {
                final bytes = await file.readAsBytes();
                _saveFile(bytes, filename);
              },
            ),
            if (timestamp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_formatTime(timestamp), style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ),
          ],
        );
      }
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message['content'] ?? ""),
          if (timestamp != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_formatTime(timestamp), style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
  Future<void> dispose() async {
    _messageController.dispose();
    _scrollController.dispose();
    _messagingService.dispose();
    _signalingService.dispose();
    await _peerConnectionService?.disposeWhenComplete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Chat with ${widget.recipient}")),
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
                  onPressed: _sendFile,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(hintText: "Type a message..."),
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
