import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../components/peer_videoConnectionService.dart';


class CallScreen extends StatefulWidget {
  final PeerVideoConnectionService connectionService;

  const CallScreen({super.key, required this.connectionService});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _micEnabled = true;
  bool _camEnabled = true;

  @override
  void initState() {
    super.initState();
    _initializeRenderers();
    _bindStreams();
  }

  void _initializeRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      final localStream = widget.connectionService.localStream;
      if (localStream != null) {
        _localRenderer.srcObject = localStream;
      } else {
        _showErrorDialog("Could not access camera/microphone");
      }
    } catch (e) {
      _showErrorDialog("Failed to initialize video: $e");
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text("Connection Error"),
        content: Text(message),
        actions: [
          TextButton(
            child: Text("Exit"),
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop(); // Exit call screen
            },
          ),
        ],
      ),
    );
  }

  void _bindStreams() {
    widget.connectionService.onRemoteStream = (stream) {
      setState(() {
        _remoteRenderer.srcObject = stream;
      });
    };
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    widget.connectionService.dispose();
    super.dispose();
  }

  void _toggleMic() {
    _micEnabled = !_micEnabled;
    widget.connectionService.toggleMic(_micEnabled);
    setState(() {});
  }

  void _toggleCam() {
    _camEnabled = !_camEnabled;
    widget.connectionService.toggleCamera(_camEnabled);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Video Call"),
        backgroundColor: Colors.grey[900],
      ),
      body: Stack(
        children: [
          RTCVideoView(
            _remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
          Positioned(
            top: 20,
            right: 20,
            width: 120,
            height: 160,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white38),
              ),
              child: RTCVideoView(
                _localRenderer,
                mirror: true,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              onPressed: _toggleMic,
              icon: Icon(
                _micEnabled ? Icons.mic : Icons.mic_off,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: _toggleCam,
              icon: Icon(
                _camEnabled ? Icons.videocam : Icons.videocam_off,
                color: Colors.white,
              ),
            ),
            IconButton(
              onPressed: () async {
                Navigator.pop(context);
              },
              icon: const Icon(Icons.call_end, color: Colors.red),
            ),
          ],
        ),
      ),
    );
  }
}