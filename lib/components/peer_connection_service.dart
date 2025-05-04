import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nexus/service/api_service.dart';
import 'signaling_service.dart';
import 'package:path_provider/path_provider.dart';


class PeerConnectionService {
  final String username;
  final String recipient;
  final SignalingService signalingService;

  late RTCPeerConnection _peerConnection;
  RTCDataChannel? _dataChannel;
  bool _isDataChannelOpen = false;
  bool _remoteDescriptionSet = false;
  bool isInitiator = false;

  final List<Uint8List> _receivedChunks = [];
  final List<RTCIceCandidate> _pendingCandidates = [];

  Function(String filePath, String mimeType)? onFileReceived;


  PeerConnectionService({
    required this.username,
    required this.recipient,
    required this.signalingService,
  });

  Future<void> initialize({required bool asInitiator}) async {
    isInitiator = asInitiator;
     final ice = await ApiService.getIceServers();
    _peerConnection = await createPeerConnection({
      'iceServers': ice,
      'iceTransportPolicy': 'relay'  // Optional: use 'relay' to force TURN
    });

    _peerConnection.onIceCandidate = (candidate) {
      signalingService.sendSignal({
        'type': 'ice',
        'recipient': recipient,
        'sender': username,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection.onDataChannel = (channel) {
      _dataChannel = channel;
      _setupDataChannelHandlers();
    };

    if (isInitiator) {
      _dataChannel = await _peerConnection.createDataChannel("fileTransfer", RTCDataChannelInit());
      _setupDataChannelHandlers();

      final offer = await _peerConnection.createOffer();
      await _peerConnection.setLocalDescription(offer);

      signalingService.sendSignal({
        'type': 'offer',
        'sdp': offer.sdp,
        'recipient': recipient,
        'sender': username,
      });
    }

    _peerConnection.onConnectionState = (state) {
      print("Connection state: $state");
    };
  }


  void _setupDataChannelHandlers() {
    _dataChannel!.onDataChannelState = (state) {
      _isDataChannelOpen = state == RTCDataChannelState.RTCDataChannelOpen;
    };

    _dataChannel!.onMessage = _onMessageHandler;
  }
  Future<void> sendFileFromPath(
      String filePath, {
        required String mimeType,
        required String fileName,
      }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      print("❌ File not found at path: $filePath");
      return;
    }

    final fileSize = await file.length();
    const chunkSize = 16 * 1024;

    print("📦 Preparing to send file: $fileName");
    print("📐 Size: $fileSize bytes | MIME: $mimeType");

    if (_dataChannel == null) {
      print("⚠️ No data channel, creating one...");
      _dataChannel = await _peerConnection.createDataChannel("fileTransfer", RTCDataChannelInit());
      _setupDataChannelHandlers();
    }

    int attempts = 0;
    while (!_isDataChannelOpen && attempts < 30) {
      print("⏳ Waiting for data channel to open... Attempt: $attempts");
      await Future.delayed(const Duration(milliseconds: 300));
      attempts++;
    }

    if (!_isDataChannelOpen) {
      print("❌ Data channel failed to open after $attempts attempts.");
      return;
    }

    final metadata = {
      "type": "file-metadata",
      "mimeType": mimeType,
      "filename": fileName,
      "length": fileSize,
    };

    print("📨 Sending metadata: $metadata");
    await _dataChannel!.send(RTCDataChannelMessage(jsonEncode(metadata)));

    final raf = file.openSync(mode: FileMode.read);
    int offset = 0;
    int chunkIndex = 0;

    while (offset < fileSize) {
      final len = (offset + chunkSize > fileSize) ? fileSize - offset : chunkSize;
      final chunk = raf.readSync(len);

      while (_dataChannel!.bufferedAmount != null &&
          _dataChannel!.bufferedAmount! > 4 * 1024 * 1024) {
        print("📥 Buffered too much, waiting...");
        await Future.delayed(const Duration(milliseconds: 50));
      }

      print("🔼 Sending chunk $chunkIndex | Offset: $offset | Size: ${chunk.length}");
      await _dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
      offset += len;
      chunkIndex++;
    }

    raf.closeSync();

    print("✅ All chunks sent. Sending EOF...");
    await _dataChannel!.send(RTCDataChannelMessage("EOF"));

    markTransferComplete();
    print("🎉 File transfer complete.");
  }



  // Future<void> sendFile(Uint8List fileBytes, {required String mimeType, required String fileName}) async {
  //   if (_dataChannel == null) {
  //     _dataChannel = await _peerConnection.createDataChannel("fileTransfer", RTCDataChannelInit());
  //     _setupDataChannelHandlers();
  //   }
  //
  //   int attempts = 0;
  //   while (!_isDataChannelOpen && attempts < 30) {
  //     await Future.delayed(Duration(milliseconds: 300));
  //     attempts++;
  //   }
  //
  //   if (!_isDataChannelOpen) {
  //     print("Data channel failed to open");
  //     return;
  //   }
  //
  //   const chunkSize = 16 * 1024;
  //
  //   await _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
  //     "type": "file-metadata",
  //     "mimeType": mimeType,
  //     "filename": fileName,
  //     "length": fileBytes.length,
  //   })));
  //
  //   for (int i = 0; i < fileBytes.length; i += chunkSize) {
  //     final chunk = fileBytes.sublist(i, i + chunkSize > fileBytes.length ? fileBytes.length : i + chunkSize);
  //     await _dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
  //   }
  //
  //   await _dataChannel!.send(RTCDataChannelMessage("EOF"));
  //   markTransferComplete();
  // }

  IOSink? _fileSink;
  String? _incomingFilename;
  String? _incomingMimeType;

  bool _metadataReceived = false;

  List<Uint8List> _earlyChunks = [];

  Future<void> _onMessageHandler(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      if (_fileSink == null) {
        print("Binary received before metadata — buffering.");
        _earlyChunks.add(message.binary); // Buffer until metadata arrives
        return;
      }

      _fileSink?.add(message.binary);
      print("🔽 Received binary chunk: ${message.binary.length} bytes");
    } else {
      final text = message.text;
      print("📩 Received text message: $text");

      if (text == 'EOF') {
        await _fileSink?.flush();
        await _fileSink?.close();
        _fileSink = null;

        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/$_incomingFilename';
        print("📁 File saved at: $path");

        onFileReceived?.call(path, _incomingMimeType ?? 'application/octet-stream');
      } else {
        try {
          final metadata = jsonDecode(text);
          if (metadata['type'] == 'file-metadata') {
            _incomingMimeType = metadata['mimeType'];
            _incomingFilename = metadata['filename'];

            final dir = await getApplicationDocumentsDirectory();
            final file = File('${dir.path}/$_incomingFilename');
            _fileSink = file.openWrite();

            print("📄 Received metadata: $metadata");

            // Flush buffered chunks
            for (final chunk in _earlyChunks) {
              _fileSink?.add(chunk);
              print("🧠 Writing buffered chunk: ${chunk.length} bytes");
            }
            _earlyChunks.clear();
          }
        } catch (e) {
          print("❌ Failed to parse metadata: $e");
        }
      }
    }
  }




  Future<void> handleSignal(Map<String, dynamic> data) async {
    switch (data['type']) {
      case 'offer':
        await _peerConnection.setRemoteDescription(
          RTCSessionDescription(data['sdp'], 'offer'),
        );
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();

        final answer = await _peerConnection.createAnswer();
        await _peerConnection.setLocalDescription(answer);

        signalingService.sendSignal({
          'type': 'answer',
          'sdp': answer.sdp,
          'recipient': data['sender'],
          'sender': username,
        });
        break;

      case 'answer':
        await _peerConnection.setRemoteDescription(
          RTCSessionDescription(data['sdp'], 'answer'),
        );
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();
        break;

      case 'ice':
        final candidate = RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        );

        if (_remoteDescriptionSet) {

          await _peerConnection.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
        break;

      default:
        print("Unknown signal type: ${data['type']}");
    }
  }

  Future<void> _flushPendingCandidates() async {
    for (final candidate in _pendingCandidates) {
      await _peerConnection.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  bool _isTransferComplete = false;

  void markTransferComplete() {
    _isTransferComplete = true;
  }

  Future<void> disposeWhenComplete() async {
    while (!_isTransferComplete) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await dispose();
  }

  Future<void> dispose() async {
    await _dataChannel?.close();
    await _peerConnection.close();
    await _peerConnection.dispose();
  }
}