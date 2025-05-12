import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nexus/service/api_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'signaling_service.dart';

/// Peer-to-peer video connection service that works reliably on both devices
class PeerVideoConnectionService {
  // ——————————————————— Constructor & public fields ———————————————————— //
  final String username;
  final String recipient;
  final SignalingService signalingService;

  PeerVideoConnectionService({
    required this.username,
    required this.recipient,
    required this.signalingService,
    this.onLocalStream,
    this.onRemoteStream,
    this.onConnectionStateChange,
    this.onError,
  });

  // ———————————————————— Callbacks ———————————————————————— //
  void Function(MediaStream stream)? onLocalStream;
  void Function(MediaStream stream)? onRemoteStream;
  void Function(RTCPeerConnectionState state)? onConnectionStateChange;
  void Function(String error)? onError;

  // ———————————————————— Private state —————————————————————— //
  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;
  MediaStream? _screen;
  final _pending = <RTCIceCandidate>[];
  bool _remoteDescSet = false;
  bool _screening = false;
  bool _disposed = false;
  bool isInitiator = false;

  // ———————————————————— Getters —————————————————————————— //
  MediaStream? get localStream => _screening ? _screen : _local;
  MediaStream? get remoteStream => _remote;
  bool get isScreenSharing => _screening;

  // ═════════════════════ INITIALIZE ═══════════════════════════════ //
  Future<void> initialize({required bool asInitiator}) async {
    try {
      isInitiator = asInitiator;
      _log("Initializing video connection as ${isInitiator ? 'initiator' : 'receiver'}");

      final ice = await ApiService.getIceServers();
      if (ice == null) {
        _err('Unable to fetch ICE servers');
        return;
      }
      print("Hi Ice --------------->");
      print(ice);

      // Create peer connection with Unified Plan semantics
      _pc = await createPeerConnection({
        'iceServers': ice,
        'iceTransportPolicy': 'all',
        'sdpSemantics': 'unified-plan',  // Modern approach with better compatibility
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      if (_pc == null) {
        _err('Failed to create peer connection');
        return;
      }

      _wireEvents();
      await _startLocalMedia();

      if (isInitiator) {
        await _createAndSendOffer();
      }
    } catch (e) {
      _err('Initialization error: $e');
    }
  }

  // ═════════════════════ LOCAL MEDIA ═════════════════════════════ //
  Future<void> _startLocalMedia() async {
    try {
      _log("Starting media capture");

      // Use simple constraints to avoid issues
      final mediaConstraints = {
        'audio': true,
        'video': {
          'mandatory': {
            'minWidth': '640',
            'minHeight': '480',
            'minFrameRate': '30',
          },
          'facingMode': 'user',
          'optional': [],
        }
      };

      _local = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _log("Media capture started with ${_local?.getTracks().length ?? 0} tracks");

      // Notify UI immediately
      if (_local != null) {
        onLocalStream?.call(_local!);
      }

      // Add tracks individually to the peer connection
      if (_pc != null && _local != null) {
        for (var track in _local!.getTracks()) {
          await _pc!.addTrack(track, _local!);
          _log("Added ${track.kind} track to peer connection");
        }
      }
    } catch (e) {
      _err('Media access error: $e');
    }
  }

  // ════════════════ PEER CONNECTION EVENTS ═══════════════════════ //
  void _wireEvents() {
    final pc = _pc!;

    // Handle ICE candidates
    pc.onIceCandidate = (candidate) {
      if (_disposed) return;

      _log("Generated ICE candidate - sending to $recipient");
      signalingService.sendSignal({
        'type': 'ice',
        'mode': 'video',
        'recipient': recipient,
        'sender': username,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };


    // Handle remote stream - this is for Unified Plan
    pc.onTrack = (RTCTrackEvent event) {
      if (_disposed) return;
      if (event.track.kind != 'video' && event.track.kind != 'audio') return;

      _log("Remote track received: ${event.track.kind}, enabled: ${event.track.enabled}");

      // Make sure the track is enabled
      event.track.enabled = true;

      if (event.streams.isNotEmpty) {
        // Use the stream that comes with the track event
        _remote = event.streams.first;
        _log("Using stream from track event: ${_remote!.id}");
        onRemoteStream?.call(_remote!);
      } else if (_remote == null) {
        // If no stream came with the event and we don't have a remote stream yet,
        // create one using the WebRTC API
        _log("Creating new MediaStream for remote track");
        createLocalMediaStream('remote').then((stream) {
          _remote = stream;
          _remote!.addTrack(event.track);
          _log("Created new remote stream and added track");
          onRemoteStream?.call(_remote!);
        });
      } else {
        // We already have a remote stream, just add the track
        _log("Adding track to existing remote stream");
        _remote!.addTrack(event.track);
        onRemoteStream?.call(_remote!);
      }
    };
    // Handle connection state changes
    pc.onConnectionState = (state) {
      _log("Connection state changed to: $state");
      onConnectionStateChange?.call(state);

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _err('Peer connection lost');
        _autoReconnect();
      }
    };

    // Handle ICE connection state changes
    pc.onIceConnectionState = (state) {
      _log("ICE connection state changed to: $state");

      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _err('ICE connection failed');
        _autoReconnect();
      }
    };

    // Handle renegotiation
    pc.onRenegotiationNeeded = () {
      _log("Renegotiation needed");
      if (!_disposed && isInitiator) {
        _createAndSendOffer();
      }
    };
  }

  // ═════════════════════ SDP FLOW ════════════════════════════════ //
  Future<void> _createAndSendOffer() async {
    try {
      if (_pc == null) return;

      _log("Creating offer");

      // Create offer with explicit constraints
      final offerOptions = {
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      };

      final offer = await _pc!.createOffer(offerOptions);
      _log("Offer created");

      await _pc!.setLocalDescription(offer);
      _log("Local description set");

      signalingService.sendSignal({
        'type': 'offer',
        'mode': 'video',
        'recipient': recipient,
        'sender': username,
        'sdp': offer.sdp,
      });

      _log("Offer sent to $recipient");
    } catch (e) {
      _err("Offer creation error: $e");
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    try {
      _log("Handling offer from ${data['sender']}");

      if (_local == null) {
        await _startLocalMedia();
      }

      await _pc!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
      _log("Remote description (offer) set");

      _remoteDescSet = true;
      await _flushPending();

      final answerOptions = {
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      };

      final answer = await _pc!.createAnswer(answerOptions);
      _log("Answer created");

      await _pc!.setLocalDescription(answer);
      _log("Local description (answer) set");

      signalingService.sendSignal({
        'type': 'answer',
        'mode': 'video',
        'recipient': data['sender'],
        'sender': username,
        'sdp': answer.sdp,
      });

      _log("Answer sent to ${data['sender']}");
    } catch (e) {
      _err("Error handling offer: $e");
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    try {
      _log("Handling answer from ${data['sender']}");

      await _pc!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'answer'));
      _log("Remote description (answer) set");

      _remoteDescSet = true;
      await _flushPending();
    } catch (e) {
      _err("Error handling answer: $e");
    }
  }

  // ═════════════════════ ICE FLOW ════════════════════════════════ //
  Future<void> _handleIce(Map<String, dynamic> data) async {
    _log("Handling ICE candidate from ${data['sender']}");

    final candidate = RTCIceCandidate(
      data['candidate'],
      data['sdpMid'],
      data['sdpMLineIndex'],
    );

    if (_remoteDescSet && _pc != null) {
      try {
        await _pc!.addCandidate(candidate);
        _log("ICE candidate added");
      } catch (e) {
        _log("Error adding ICE candidate: $e");
      }
    } else {
      _log("Storing ICE candidate for later");
      _pending.add(candidate);
    }
  }

  Future<void> _flushPending() async {
    if (_pc == null) return;

    _log("Adding ${_pending.length} stored ICE candidates");

    for (final candidate in _pending) {
      try {
        await _pc!.addCandidate(candidate);
        _log("Stored ICE candidate added");
      } catch (e) {
        _log("Error adding stored ICE candidate: $e");
      }
    }

    _pending.clear();
  }

  // ═══════════════ SCREEN SHARING ════════════════════ //
  Future<bool> startForegroundService() async {
    final androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: "Screen Sharing",
      notificationText: "Screen sharing is active",
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon: AndroidResource(
        name: 'notification_icon',
        defType: 'drawable',
      ),
    );
    return await FlutterBackground.initialize(androidConfig: androidConfig) &&
        await FlutterBackground.enableBackgroundExecution();
  }

  Future<bool> toggleScreenSharing() async {
    return _screening ? await _stopShare() : await _startShare();
  }

  Future<bool> _startShare() async {
    try {
      _log("Starting screen sharing");
      final androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: "Screen Sharing",
        notificationText: "Your screen is being shared",
        notificationImportance: AndroidNotificationImportance.high,

      );

      final hasPermissions = await FlutterBackground.initialize(androidConfig: androidConfig);
      if (!hasPermissions) {
        print("Background service permission denied");
        return false;
      }

      await FlutterBackground.enableBackgroundExecution();

      await Permission.microphone.request();

      _screen = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });

      if (_screen == null) {
        _err("Failed to get screen sharing stream");
        return false;
      }

      _log("Screen sharing started");

      // Replace track rather than stream for Unified Plan
      if (_pc != null && _screen != null) {
        final videoTrack = _screen!.getVideoTracks().first;

        // Find all senders
        final senders = await _pc!.getSenders();

        // Find video sender
        RTCRtpSender? videoSender;
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            videoSender = sender;
            break;
          }
        }

        if (videoSender != null) {
          await videoSender.replaceTrack(videoTrack);
          _log("Replaced video track with screen sharing track");
        } else {
          _log("No video sender found, adding screen sharing track");
          await _pc!.addTrack(videoTrack, _screen!);
        }

        // Handle when user stops screen sharing via browser UI
        videoTrack.onEnded = () {
          _log("Screen sharing stopped by user");
          _stopShare();
        };
      }

      // Set flag
      _screening = true;

      // Notify UI of the new local stream
      onLocalStream?.call(_screen!);

      // Signal to other peer that we're now screen sharing
      signalingService.sendSignal({
        'type': 'screen-sharing-status',
        'mode': 'video',
        'isScreenSharing': true,
        'recipient': recipient,
        'sender': username,
      });

      return true;
    } catch (e) {
      _err("Failed to start screen sharing: $e");
      await _screen?.dispose();
      _screen = null;
      return false;
    }
  }

  Future<bool> _stopShare() async {
    if (!_screening || _screen == null) return false;

    try {
      _log("Stopping screen sharing");
      if (WebRTC.platformIsAndroid) {
        await FlutterBackground.disableBackgroundExecution();
      }
      // Stop all tracks in screen stream
      for (var track in _screen!.getTracks()) {
        track.stop();
      }

      // Replace screen sharing track with camera track
      if (_pc != null && _local != null && _local!.getVideoTracks().isNotEmpty) {
        final videoTrack = _local!.getVideoTracks().first;

        // Find all senders
        final senders = await _pc!.getSenders();

        // Find video sender
        RTCRtpSender? videoSender;
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            videoSender = sender;
            break;
          }
        }

        if (videoSender != null) {
          await videoSender.replaceTrack(videoTrack);
          _log("Replaced screen sharing track with camera track");
        } else {
          _log("No video sender found, adding camera track");
          await _pc!.addTrack(videoTrack, _local!);
        }

        // Notify UI of the stream change
        onLocalStream?.call(_local!);
      }

      // Dispose screen stream
      await _screen!.dispose();
      _screen = null;
      _screening = false;

      // Signal to other peer that we've stopped screen sharing
      signalingService.sendSignal({
        'type': 'screen-sharing-status',
        'mode': 'video',
        'isScreenSharing': false,
        'recipient': recipient,
        'sender': username,
      });

      return true;
    } catch (e) {
      _err("Error stopping screen sharing: $e");
      return false;
    }
  }

  // ═════════════════════ TOGGLES ══════════════════════════════════ //
  void toggleMic(bool enable) {
    if (_local == null) return;

    for (var track in _local!.getAudioTracks()) {
      track.enabled = enable;
      _log("Microphone ${enable ? 'enabled' : 'disabled'}");
    }
  }

  void toggleCamera(bool enable) {
    final stream = _screening ? _screen : _local;
    if (stream == null) return;

    for (var track in stream.getVideoTracks()) {
      track.enabled = enable;
      _log("Camera ${enable ? 'enabled' : 'disabled'}");
    }
  }

  // Added method to ensure tracks are enabled
  void ensureTracksEnabled() {
    if (_local != null) {
      for (var track in _local!.getVideoTracks()) {
        if (!track.enabled) {
          _log("Enabling disabled local video track");
          track.enabled = true;
        }
      }

      for (var track in _local!.getAudioTracks()) {
        if (!track.enabled) {
          _log("Enabling disabled local audio track");
          track.enabled = true;
        }
      }
    }

    if (_remote != null) {
      for (var track in _remote!.getVideoTracks()) {
        if (!track.enabled) {
          _log("Enabling disabled remote video track");
          track.enabled = true;
        }
      }

      for (var track in _remote!.getAudioTracks()) {
        if (!track.enabled) {
          _log("Enabling disabled remote audio track");
          track.enabled = true;
        }
      }
    }
  }

  // ═════════════════════ SIGNAL ENTRY ═════════════════════════════ //
  Future<void> handleSignal(Map<String, dynamic> data) async {
    if (_disposed || _pc == null) return;

    final type = data['type'];
    _log("Handling signal of type: $type from ${data['sender']}");

    try {
      switch (type) {
        case 'offer':
          await _handleOffer(data);
          break;
        case 'answer':
          await _handleAnswer(data);
          break;
        case 'ice':
          await _handleIce(data);
          break;
        case 'reject':
          _err("Call rejected");
          dispose();
          break;
        case 'screen-sharing-status':
          final isRemoteScreenSharing = data['isScreenSharing'] as bool;
          _log("Remote peer ${isRemoteScreenSharing ? 'started' : 'stopped'} screen sharing");
          break;
        default:
          _log("Unknown signal type: $type");
      }
    } catch (e) {
      _err("Signal handling error: $e");
    }
  }

  // Added method to debug connection state
  void debugConnectionState() {
    if (_pc == null) {
      _log("No peer connection available");
      return;
    }

    final state = _pc!.connectionState;
    final iceState = _pc!.iceConnectionState;

    _log("Current connection state: $state");
    _log("Current ICE connection state: $iceState");

    if (_local != null) {
      _log("Local tracks: ${_local!.getTracks().length}");
      for (var track in _local!.getTracks()) {
        _log("Local ${track.kind} track, enabled: ${track.enabled}");
      }
    }

    if (_remote != null) {
      _log("Remote tracks: ${_remote!.getTracks().length}");
      for (var track in _remote!.getTracks()) {
        _log("Remote ${track.kind} track, enabled: ${track.enabled}");
      }
    }
  }

  // ═════════════════════ UTIL / CLEANUP ═══════════════════════════ //
  int _reconnectAttempts = 0;
  final int _maxReconnectAttempts = 5;

  void _autoReconnect() {
    if (!_disposed && isInitiator && _reconnectAttempts < _maxReconnectAttempts) {
      _log("Attempting automatic reconnection (${_reconnectAttempts + 1}/$_maxReconnectAttempts)");
      _reconnectAttempts++;
      Future.delayed(Duration(seconds: _reconnectAttempts * 2), reconnect);
    } else if (_reconnectAttempts >= _maxReconnectAttempts) {
      _err("Max reconnection attempts reached");
    }
  }

  void _log(String message) {
    print('[P2P-VIDEO] $message');
  }

  void _err(String message) {
    print('[P2P-VIDEO ERROR] $message');
    onError?.call(message);
  }

  Future<void> dispose() async {
    if (_disposed) return;

    _log("Disposing PeerVideoConnectionService");
    _disposed = true;

    try {
      // Stop screen sharing if active
      if (_screen != null) {
        _screen!.getTracks().forEach((track) => track.stop());
        await _screen!.dispose();
      }

      // Stop all tracks and dispose streams
      if (_local != null) {
        _local!.getTracks().forEach((track) => track.stop());
        await _local!.dispose();
      }

      if (_remote != null) {
        _remote!.getTracks().forEach((track) => track.stop());
        await _remote!.dispose();
      }

      // Close peer connection
      await _pc?.close();

      _pc = null;
      _local = null;
      _remote = null;
      _screen = null;
      _pending.clear();

      _log("PeerVideoConnectionService disposed successfully");
    } catch (e) {
      _log("Error during disposal: $e");
    }
  }

  Future<void> reconnect() async {
    _log("Reconnecting PeerVideoConnectionService");
    await dispose();
    _disposed = false;
    _remoteDescSet = false;
    _reconnectAttempts = 0;
    await initialize(asInitiator: isInitiator);
  }
}