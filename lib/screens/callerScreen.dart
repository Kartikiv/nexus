import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_background/flutter_background.dart';

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
  bool _isScreenSharing = false;
  bool _remoteVideoAvailable = false;
  bool _localVideoAvailable = false;

  @override
  void initState() {
    super.initState();
    _initializeRenderers();
  }

  Future<void> _initializeRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      // Set up stream listeners
      _bindStreams();

      // Check if we already have streams
      _checkInitialStreams();
    } catch (e) {
      print("Error initializing renderers: $e");
      _showErrorDialog("Failed to initialize video: $e");
    }
  }

  void _checkInitialStreams() {
    // Set initial local stream
    final localStream = widget.connectionService.localStream;
    if (localStream != null) {
      setState(() {
        _localRenderer.srcObject = localStream;
        _localVideoAvailable = localStream.getVideoTracks().isNotEmpty;
      });

      // Update local video status when tracks change
      localStream.onAddTrack = (track) {
        if (track.kind == 'video') {
          setState(() => _localVideoAvailable = true);
        }
      };
    }

    // Set initial remote stream
    final remoteStream = widget.connectionService.remoteStream;
    if (remoteStream != null) {
      setState(() {
        _remoteRenderer.srcObject = remoteStream;
        _remoteVideoAvailable = remoteStream.getVideoTracks().isNotEmpty;
      });

      // Update remote video status when tracks change
      remoteStream.onAddTrack = (track) {
        if (track.kind == 'video') {
          setState(() => _remoteVideoAvailable = true);
        }
      };
    }
  }

  void _bindStreams() {
    // Listen for local stream changes
    widget.connectionService.onLocalStream = (stream) {
      print("Local stream updated: ${stream.id}");
      print("Local video tracks: ${stream.getVideoTracks().length}");
      if (stream.getVideoTracks().isNotEmpty) {
        print("Local video track enabled: ${stream.getVideoTracks().first.enabled}");
      }
      setState(() {
        _localRenderer.srcObject = stream;
        _localVideoAvailable = stream.getVideoTracks().isNotEmpty;
        _isScreenSharing = widget.connectionService.isScreenSharing;
      });
    };

    // Listen for remote stream changes
    widget.connectionService.onRemoteStream = (stream) {
      print("Remote stream updated: ${stream.id}");
      print("Remote video tracks: ${stream.getVideoTracks().length}");
      print("Remote audio tracks: ${stream.getAudioTracks().length}");

      setState(() {
        _remoteRenderer.srcObject = stream;
        _remoteVideoAvailable = stream.getVideoTracks().isNotEmpty;
      });
    };

    // Listen for connection state changes
    widget.connectionService.onConnectionStateChange = (state) {
      print("Connection state changed: $state");

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _showErrorDialog("Call connection lost");
      }
    };
  }

  void _showErrorDialog(String message) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Connection Error"),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text("Exit"),
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop(); // Exit call screen
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _toggleMic() {
    setState(() => _micEnabled = !_micEnabled);
    widget.connectionService.toggleMic(_micEnabled);
  }

  void _toggleCam() {
    setState(() => _camEnabled = !_camEnabled);
    widget.connectionService.toggleCamera(_camEnabled);
  }

  Future<void> _toggleScreenSharing() async {
    try {
      final success = await widget.connectionService.toggleScreenSharing();
      if (success) {
        setState(() {
          _isScreenSharing = widget.connectionService.isScreenSharing;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Screen sharing error: $e"))
      );
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Video Call"),
        backgroundColor: Colors.grey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              // Force refresh the connection
              widget.connectionService.reconnect();
            },
            tooltip: 'Reconnect',
          ),
        ],
      ),
      body: OrientationBuilder(
          builder: (context, orientation) {
            return Stack(
              children: [
                // Remote video (full screen)
                Container(
                  color: Colors.black87,
                  child: _remoteVideoAvailable
                      ? RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    mirror: false,
                  )
                      : const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white54),
                        SizedBox(height: 16),
                        Text(
                          "Waiting for other participant's video...",
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),

                // Local video (picture-in-picture)
                Positioned(
                  top: 20,
                  right: 20,
                  width: orientation == Orientation.portrait ? 120 : 160,
                  height: orientation == Orientation.portrait ? 160 : 120,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white38),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.black45,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _localVideoAvailable
                          ? RTCVideoView(
                        _localRenderer,
                        mirror: !_isScreenSharing,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                          : const Center(
                        child: Text(
                          "Camera not available",
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),

                // Screen sharing indicator
                if (_isScreenSharing)
                  Positioned(
                    top: 20,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.screen_share, color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Text(
                            "Screen Sharing",
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          }
      ),
      bottomNavigationBar: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Microphone toggle
              IconButton(
                onPressed: _toggleMic,
                icon: Icon(
                  _micEnabled ? Icons.mic : Icons.mic_off,
                  color: _micEnabled ? Colors.white : Colors.red,
                ),
                tooltip: _micEnabled ? 'Mute microphone' : 'Unmute microphone',
              ),

              // Camera toggle
              IconButton(
                onPressed: _toggleCam,
                icon: Icon(
                  _camEnabled ? Icons.videocam : Icons.videocam_off,
                  color: _camEnabled ? Colors.white : Colors.red,
                ),
                tooltip: _camEnabled ? 'Turn off camera' : 'Turn on camera',
              ),

              // Screen sharing toggle
              IconButton(
                onPressed: _toggleScreenSharing,
                icon: Icon(
                  _isScreenSharing ? Icons.stop_screen_share : Icons.screen_share,
                  color: _isScreenSharing ? Colors.red : Colors.white,
                ),
                tooltip: _isScreenSharing ? 'Stop screen sharing' : 'Share screen',
              ),

              // End call button
              IconButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.call_end, color: Colors.red),
                tooltip: 'End call',
              ),
            ],
          ),
        ),
      ),
    );
  }
}