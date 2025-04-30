import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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

    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
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
    if (!file.existsSync()) return;

    final fileSize = await file.length();
    const chunkSize = 16 * 1024;

    if (_dataChannel == null) {
      _dataChannel = await _peerConnection.createDataChannel("fileTransfer", RTCDataChannelInit());
      _setupDataChannelHandlers();
    }

    int attempts = 0;
    while (!_isDataChannelOpen && attempts < 30) {
      await Future.delayed(const Duration(milliseconds: 300));
      attempts++;
    }

    if (!_isDataChannelOpen) {
      print("Data channel failed to open");
      return;
    }

    await _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
      "type": "file-metadata",
      "mimeType": mimeType,
      "filename": fileName,
      "length": fileSize,
    })));

    final raf = file.openSync(mode: FileMode.read);
    int offset = 0;

    while (offset < fileSize) {
      final len = (offset + chunkSize > fileSize) ? fileSize - offset : chunkSize;
      final chunk = raf.readSync(len);

      while (_dataChannel!.bufferedAmount != null &&
          _dataChannel!.bufferedAmount! > 4 * 1024 * 1024) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      await _dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
      offset += len;
    }

    raf.closeSync();
    await _dataChannel!.send(RTCDataChannelMessage("EOF"));
    markTransferComplete();
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

  Future<void> _onMessageHandler(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      _fileSink?.add(message.binary);
    } else {
      final text = message.text;
      if (text == 'EOF') {
        await _fileSink?.flush();
        await _fileSink?.close();
        _fileSink = null;

        if (_incomingFilename != null && onFileReceived != null) {
          final dir = await getApplicationDocumentsDirectory();
          final path = '${dir.path}/$_incomingFilename';
          onFileReceived?.call(path, _incomingMimeType ?? 'application/octet-stream');
        }
      } else {
        try {
          final metadata = jsonDecode(text);
          if (metadata['type'] == 'file-metadata') {
            _incomingMimeType = metadata['mimeType'];
            _incomingFilename = metadata['filename'];

            final dir = await getApplicationDocumentsDirectory();
            final file = File('${dir.path}/$_incomingFilename');
            _fileSink = file.openWrite();
          }
        } catch (_) {
          print("Unrecognized message: $text");
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