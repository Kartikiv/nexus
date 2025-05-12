import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../components/messaging_service.dart';
import '../components/peer_connection_service.dart';
import '../components/peer_videoConnectionService.dart';
import '../components/signaling_service.dart';
import 'package:mime/mime.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../components/video_preview_widget.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'callerScreen.dart';

class ChatScreen extends StatefulWidget {
  final String username;
  final String recipient;
  final String recipientName;

  const ChatScreen({super.key, required this.username, required this.recipient, required this.recipientName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late MessagingService _messagingService;
  late SignalingService _signalingService;
  PeerConnectionService? _peerConnectionService;
  PeerVideoConnectionService? _peerVideoConnectionService;

  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late SharedPreferences _prefs;

  late final String? jwt;
  bool _isProcessingCall = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    await _loadStoredMessages();

    jwt = prefs.getString('auth_token');
    if (jwt == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Authentication error. Please log in again."))
      );
      Navigator.of(context).pushReplacementNamed('/');
      return;
    }

    _messagingService = MessagingService(
      username: widget.username,
      recipient: widget.recipient,
      onMessageReceived: (msg) async {
        setState(() => _messages.add(msg));
        await _saveMessages();
        _scrollToBottom();
      },
    );

    _signalingService = SignalingService(
      username: widget.username,
      recipient: widget.recipient,
      onSignalReceived: (data) async {
        final type = data['type'];
        final mode = data['mode'] ?? 'file';
        final sender = data['sender'];

        // Only process messages from the right sender
        if (sender != widget.recipient) return;

        if (mode == 'file') {
          await _handleFileSignal(data, type);
        } else if (mode == 'video') {
          await _handleVideoSignal(data, type);
        }
      },
    );

    _messagingService.connect(jwt!);
    _signalingService.connect(jwt!);

    // Scroll to bottom after loading messages
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  Future<void> _handleFileSignal(Map<String, dynamic> data, String type) async {
    if (type == 'offer') {
      _peerConnectionService ??= PeerConnectionService(
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
        if (mounted) setState(() => _messages.add(msg));
        await _saveMessages();
        _scrollToBottom();
      };
      await _peerConnectionService!.initialize(asInitiator: false);
      await _peerConnectionService!.handleSignal(data);
    } else {
      // Only handle answer/ice if connection exists
      await _peerConnectionService?.handleSignal(data);
    }
  }

  Future<void> _handleVideoSignal(Map<String, dynamic> data, String type) async {
    // Prevent multiple concurrent call handling
    if (_isProcessingCall && type == 'offer') {
      _signalingService.sendSignal({
        'type': 'busy',
        'mode': 'video',
        'recipient': data['sender'],
        'sender': widget.username,
      });
      return;
    }

    if (type == 'offer') {
      _isProcessingCall = true;

      // Ensure we dispose any existing video connection first
      await _peerVideoConnectionService?.dispose();
      _peerVideoConnectionService = null;

      final accept = await _showIncomingCallDialog();
      if (!accept) {
        // If rejected, send rejection signal and exit
        _signalingService.sendSignal({
          'type': 'reject',
          'mode': 'video',
          'recipient': data['sender'],
          'sender': widget.username,
        });
        _isProcessingCall = false;
        return;
      }

      // Initialize new video connection service
      _peerVideoConnectionService = PeerVideoConnectionService(
        username: widget.username,
        recipient: widget.recipient,
        signalingService: _signalingService,
        onError: (error) {
          if (mounted) {

          }
        },
        onConnectionStateChange: (state) {
          // Handle connection state changes
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Call connection failed or disconnected"))
              );
              Navigator.of(context).maybePop(); // Try to close call screen if open
            }
          }
        },
      );

      try {
        // Initialize as recipient (not initiator)
        await _peerVideoConnectionService!.initialize(asInitiator: false);

        // IMPORTANT: Handle the offer signal AFTER initialization
        await _peerVideoConnectionService!.handleSignal(data);

        if (mounted) {
          // Navigate to call screen
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CallScreen(connectionService: _peerVideoConnectionService!),
            ),
          );

          // When returned from call screen, clean up
          await _peerVideoConnectionService?.dispose();
          _peerVideoConnectionService = null;
        }
      } catch (e) {
        // Handle errors
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Failed to accept call: $e"))
          );
        }
        await _peerVideoConnectionService?.dispose();
        _peerVideoConnectionService = null;
      }

      _isProcessingCall = false;
    } else if (type == 'reject') {
      // Handle rejection
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Call was declined"))
        );
      }
      await _peerVideoConnectionService?.dispose();
      _peerVideoConnectionService = null;
      _isProcessingCall = false;
    } else if (type == 'busy') {
      // Handle busy status
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Recipient is busy on another call"))
        );
      }
      await _peerVideoConnectionService?.dispose();
      _peerVideoConnectionService = null;
      _isProcessingCall = false;
    } else {
      // Handle other signal types (answer, ice)
      if (_peerVideoConnectionService != null) {
        await _peerVideoConnectionService!.handleSignal(data);
      } else {
        print("Received ${data['type']} signal but no active video connection");
      }
    }
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

  Future<void> _loadStoredMessages() async {
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

  Future<bool> _showIncomingCallDialog() async {
    return await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming Video Call'),
        content: Text('${widget.recipientName} is calling you'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Decline')
          ),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Accept')
          ),
        ],
      ),
    ) ?? false;
  }

  void _startVideoCall() async {
    if (_isProcessingCall) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Call already in progress"))
      );
      return;
    }

    _isProcessingCall = true;

    // First check permissions explicitly - important for both caller and recipient
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (cameraStatus != PermissionStatus.granted ||
        micStatus != PermissionStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Camera and microphone permissions are required for video calls"))
      );
      _isProcessingCall = false;
      return;
    }

    // Clean up any existing connections to avoid conflicts
    await _peerVideoConnectionService?.dispose();
    _peerVideoConnectionService = null;

    // Create new connection service with error handling
    _peerVideoConnectionService = PeerVideoConnectionService(
      username: widget.username,
      recipient: widget.recipient,
      signalingService: _signalingService,
      onError: (error) {
        if (mounted) {

        }
      },
      onConnectionStateChange: (state) {
        print("Connection state changed to: $state");

        // Handle failed connection state
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Call connection failed or disconnected"))
            );
            Navigator.of(context).maybePop(); // Try to close call screen if open
          }
        }
      },
    );

    try {
      // Initialize the connection as caller (initiator)
      await _peerVideoConnectionService!.initialize(asInitiator: true);

      if (mounted) {
        // Navigate to call screen with the connection service
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallScreen(connectionService: _peerVideoConnectionService!),
          ),
        );

        // Make sure to dispose the connection when returning from call screen
        await _peerVideoConnectionService?.dispose();
        _peerVideoConnectionService = null;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to start call: $e"))
        );
      }
      await _peerVideoConnectionService?.dispose();
      _peerVideoConnectionService = null;
    }

    _isProcessingCall = false;
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
    _messagingService.sendMessage(text);
    setState(() => _messages.add(msg));
    await _saveMessages();
    _messageController.clear();
    _scrollToBottom();
  }

  Future<void> _sendFile() async {
    try {
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

          if (mounted) {
            setState(() => _messages.add(msg));
            await _saveMessages();
            _scrollToBottom();
          }
        };

        await _peerConnectionService!.initialize(asInitiator: true);
      }

      // Show sending indicator
      final sentMsgTemp = {
        'sender': 'me',
        'isFile': true,
        'filePath': filePath,
        'mimeType': mimeType,
        'filename': fileName,
        'timestamp': DateTime.now(),
        'sending': true,
      };

      setState(() => _messages.add(sentMsgTemp));
      _scrollToBottom();

      await _peerConnectionService!.sendFileFromPath(
        filePath,
        mimeType: mimeType,
        fileName: fileName,
      );

      // Update message without sending indicator
      final sentMsgFinal = {
        'sender': 'me',
        'isFile': true,
        'filePath': filePath,
        'mimeType': mimeType,
        'filename': fileName,
        'timestamp': DateTime.now(),
        'sending': false,
      };

      if (mounted) {
        setState(() {
          _messages.remove(sentMsgTemp);
          _messages.add(sentMsgFinal);
        });
        await _saveMessages();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to send file: $e"))
        );
      }
    }
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
        SnackBar(content: Text("Failed to save file: $e")),
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
    final isSending = message['sending'] == true;

    Widget content;

    if (message['isFile'] == true) {
      final mimeType = message['mimeType'] ?? '';
      final filename = message['filename'] ?? 'file.bin';
      final filePath = message['filePath'];
      final file = filePath != null ? File(filePath) : null;

      if (isSending) {
        // Show sending indicator for files
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    "Sending $filename...",
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
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
      } else if (file == null || !file.existsSync()) {
        content = const Text("File not found");
      } else if (mimeType.startsWith('image/')) {
        content = _buildImageContent(file, filename, timestamp);
      } else if (mimeType.startsWith('video/')) {
        content = _buildVideoContent(file, filename, timestamp);
      } else {
        content = _buildGenericFileContent(file, filename, timestamp);
      }
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message['content'] ?? ""),
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
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: content,
      ),
    );
  }

  Widget _buildImageContent(File file, String filename, DateTime? timestamp) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => OpenFilex.open(file.path),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              file,
              height: 200,
              width: 200,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  height: 100,
                  width: 100,
                  color: Colors.grey[200],
                  child: const Icon(Icons.broken_image, size: 50),
                );
              },
            ),
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.download, size: 16),
          label: const Text("Save", style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () async {
            final bytes = await file.readAsBytes();
            _saveFile(bytes, filename);
          },
        ),
        if (timestamp != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_formatTime(timestamp),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _buildVideoContent(File file, String filename, DateTime? timestamp) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => OpenFilex.open(file.path),
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPreviewWidget(filePath: file.path,
                
              )
            ]
          ),
        ),
        const SizedBox(height: 4),
        Text(
          filename,
          style: const TextStyle(fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        TextButton.icon(
          icon: const Icon(Icons.download, size: 16),
          label: const Text("Save", style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () async {
            final bytes = await file.readAsBytes();
            _saveFile(bytes, filename);
          },
        ),
        if (timestamp != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_formatTime(timestamp),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _buildGenericFileContent(File file, String filename, DateTime? timestamp) {
    IconData iconData;
    Color iconColor;

    if (filename.endsWith('.pdf')) {
      iconData = Icons.picture_as_pdf;
      iconColor = Colors.red;
    } else if (filename.endsWith('.doc') || filename.endsWith('.docx')) {
      iconData = Icons.description;
      iconColor = Colors.blue;
    } else if (filename.endsWith('.xls') || filename.endsWith('.xlsx')) {
      iconData = Icons.table_chart;
      iconColor = Colors.green;
    } else if (filename.endsWith('.zip') || filename.endsWith('.rar')) {
      iconData = Icons.folder_zip;
      iconColor = Colors.amber;
    } else {
      iconData = Icons.insert_drive_file;
      iconColor = Colors.grey;
    }

    return GestureDetector(
      onTap: () => OpenFilex.open(file.path),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconData, color: iconColor, size: 40),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      filename,
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      "Tap to open",
                      style: TextStyle(
                        color: Colors.blue.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          TextButton.icon(
            icon: const Icon(Icons.download, size: 16),
            label: const Text("Save", style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () async {
              final bytes = await file.readAsBytes();
              _saveFile(bytes, filename);
            },
          ),
          if (timestamp != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_formatTime(timestamp),
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Future<void> dispose() async {
    _messageController.dispose();
    _scrollController.dispose();
    _messagingService.dispose();
    _signalingService.dispose();
    await _peerConnectionService?.disposeWhenComplete();
    await _peerVideoConnectionService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recipientName),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_call),
            onPressed: _startVideoCall,
            tooltip: 'Start video call',
          ),
        ],
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
                  onPressed: _sendFile,
                  tooltip: 'Send file',
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: "Type a message...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24.0)),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                  tooltip: 'Send message',
                ),
              ],
            ),
          ),
          // Add padding at bottom for better keyboard input space
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}