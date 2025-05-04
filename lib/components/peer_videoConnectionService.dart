import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nexus/service/api_service.dart';
import 'signaling_service.dart';

class PeerVideoConnectionService {
  final String username;
  final String recipient;
  final SignalingService signalingService;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  Function(MediaStream stream)? onRemoteStream;
  Function(RTCPeerConnectionState state)? onConnectionStateChange;
  Function(String error)? onError;

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  bool isInitiator = false;
  bool _isDisposed = false;

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  PeerVideoConnectionService({
    required this.username,
    required this.recipient,
    required this.signalingService,
    this.onError,
    this.onConnectionStateChange,
  });

  Future<void> initialize({required bool asInitiator}) async {
    try {
      isInitiator = asInitiator;
      final ice = await ApiService.getIceServers();
      if (ice == null) {
        _handleError("Failed to load ICE servers");
        return;
      }

      _peerConnection = await createPeerConnection({
        'iceServers': ice,
        'iceTransportPolicy': 'all',
        'sdpSemantics': 'unified-plan',
      });

      if (_peerConnection == null) {
        _handleError("Failed to create peer connection");
        return;
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (_isDisposed) return;
        signalingService.sendSignal({
          'type': 'ice',
          'recipient': recipient,
          'sender': username,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'mode': 'video',
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      _peerConnection!.onTrack = (event) {
        if (_isDisposed) return;
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          onRemoteStream?.call(_remoteStream!);
        }
      };

      _peerConnection!.onConnectionState = (state) {
        if (_isDisposed) return;
        print("Connection state: $state");
        onConnectionStateChange?.call(state);

        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _handleError("Connection failed");
        }
      };

      await _startMedia();

      if (isInitiator) {
        await _createAndSendOffer();
      }
    } catch (e) {
      _handleError("Initialization error: $e");
    }
  }

  Future<void> _startMedia() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'facingMode': 'user'}
      });

      if (_peerConnection != null && _localStream != null) {
        for (var track in _localStream!.getTracks()) {
          await _peerConnection!.addTrack(track, _localStream!);
        }
      }
    } catch (e) {
      _handleError("Media error: $e");
    }
  }

  Future<void> _createAndSendOffer() async {
    try {
      if (_peerConnection == null) return;

      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      signalingService.sendSignal({
        'type': 'offer',
        'mode': 'video',
        'sdp': offer.sdp,
        'recipient': recipient,
        'sender': username,
      });
    } catch (e) {
      _handleError("Offer creation error: $e");
    }
  }

  void toggleMic(bool enable) {
    _localStream?.getAudioTracks().forEach((track) => track.enabled = enable);
  }

  void toggleCamera(bool enable) {
    _localStream?.getVideoTracks().forEach((track) => track.enabled = enable);
  }

  Future<void> handleSignal(Map<String, dynamic> data) async {
    if (_isDisposed || _peerConnection == null) return;

    try {
      switch (data['type']) {
        case 'offer':
          await _handleOffer(data);
          break;

        case 'answer':
          await _handleAnswer(data);
          break;

        case 'ice':
          await _handleIceCandidate(data);
          break;
      }
    } catch (e) {
      _handleError("Signal handling error: $e");
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    if (_localStream == null) {
      await _startMedia();
    }

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(data['sdp'], 'offer'),
    );
    _remoteDescriptionSet = true;
    await _flushCandidates();

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    signalingService.sendSignal({
      'type': 'answer',
      'sdp': answer.sdp,
      'mode': "video",
      'recipient': data['sender'],
      'sender': username,
    });
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(data['sdp'], 'answer'),
    );
    _remoteDescriptionSet = true;
    await _flushCandidates();
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    final candidate = RTCIceCandidate(
      data['candidate'],
      data['sdpMid'],
      data['sdpMLineIndex'],
    );

    if (_remoteDescriptionSet && _peerConnection != null) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  Future<void> _flushCandidates() async {
    if (_peerConnection == null) return;

    for (final candidate in _pendingCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  void _handleError(String message) {
    print("PeerVideoConnectionService error: $message");
    onError?.call(message);
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    try {
      // Stop all tracks before disposing streams
      _localStream?.getTracks().forEach((track) async {
        await track.stop();
      });

      _remoteStream?.getTracks().forEach((track) async {
        await track.stop();
      });

      await _localStream?.dispose();
      await _remoteStream?.dispose();
      await _peerConnection?.close();

      _localStream = null;
      _remoteStream = null;
      _peerConnection = null;
    } catch (e) {
      print("Error during disposal: $e");
    }
  }

  Future<void> reconnect() async {
    await dispose();
    _isDisposed = false;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    await initialize(asInitiator: isInitiator);
  }
}