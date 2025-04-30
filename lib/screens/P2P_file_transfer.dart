
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

class P2PFileTransferScreen extends StatefulWidget {
    final String username;
    final String recipient;

  const P2PFileTransferScreen({super.key, required this.username, required this.recipient});

    @override
    State<P2PFileTransferScreen> createState() => _P2PFileTransferScreenState();
}

class _P2PFileTransferScreenState extends State<P2PFileTransferScreen> {
    RTCPeerConnection? _peerConnection;
    RTCDataChannel? _dataChannel;
    final List<String> logs = [];
    final receivedChunks = <int>[];

    void _log(String msg) => setState(() => logs.add(msg));

    @override
    void initState() {
        super.initState();
        _initConnection();
    }

    Future<void> _initConnection() async {
        final config = <String, dynamic>{
                'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };

        _peerConnection = await createPeerConnection(config);
        _peerConnection?.onDataChannel = (channel) {
                _dataChannel = channel;
        _dataChannel!.onMessage = (msg) {
                receivedChunks.addAll(msg.binary!);
        _log("📥 Received chunk of size: ${msg.binary!.length}");
      };
    };
    }

    Future<void> _createDataChannel() async {
        final channelInit = RTCDataChannelInit()..ordered = true;
        _dataChannel = await _peerConnection!.createDataChannel('fileChannel', channelInit);
        _log("✅ DataChannel created.");
    }

    Future<void> _sendFile() async {
        final result = await FilePicker.platform.pickFiles(withData: true);
        if (result != null && result.files.single.bytes != null) {
            Uint8List fileBytes = result.files.single.bytes!;
      const chunkSize = 16000;

            _log("📤 Sending ${fileBytes.length} bytes...");

            for (int i = 0; i < fileBytes.length; i += chunkSize) {
                final chunk = fileBytes.sublist(i, i + chunkSize > fileBytes.length ? fileBytes.length : i + chunkSize);
                _dataChannel?.send(RTCDataChannelMessage.fromBinary(chunk));
                await Future.delayed(const Duration(milliseconds: 10));
            }

            _log("✅ File transfer complete.");
        }
    }

    @override
    void dispose() {
        _peerConnection?.dispose();
        _dataChannel?.close();
        super.dispose();
    }

    @override
    Widget build(BuildContext context) {
        return Scaffold(
                appBar: AppBar(title: const Text("P2P File Transfer")),
        body: Column(
                children: [
        ElevatedButton(
                onPressed: _createDataChannel,
                child: const Text("Create Data Channel"),
          ),
        ElevatedButton(
                onPressed: _sendFile,
                child: const Text("Pick & Send File"),
          ),
        Expanded(
                child: ListView.builder(
                itemCount: logs.length,
                itemBuilder: (_, i) => ListTile(title: Text(logs[i])),
            ),
          ),
        ],
      ),
    );
    }
}
