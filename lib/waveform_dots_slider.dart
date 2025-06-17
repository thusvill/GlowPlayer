import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:async';


import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:just_waveform/just_waveform.dart';
import 'audio_service.dart';

class WaveformDotsSlider extends StatefulWidget {
  final Color dotColor;
  final double maxWidth;
  final VoidCallback? onPressed;

  const WaveformDotsSlider({
    super.key,
    this.dotColor = Colors.cyanAccent,
    this.maxWidth = double.infinity,
    this.onPressed,
  });

  @override
  State<WaveformDotsSlider> createState() => _WaveformDotsSliderState();
}

class _WaveformDotsSliderState extends State<WaveformDotsSlider> {
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  List<double>? _amplitudes;
  bool _isLoading = true;

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _setupAudio();
    _generateWaveform();
  }

  Future<void> _setupAudio() async {
    //await AudioService.player.setSource(DeviceFileSource(widget.filePath));
    //await AudioService.player.resume(); // autoplay
    //AudioService.isPlaying = true;

    //AudioService.play();
    AudioService.play();

    _durationSub = AudioService.player.onDurationChanged.listen((d) {
      if (d != null && mounted) {
        setState(() {
          _duration = d;
          AudioService.duration = d;
        });
      }
    });

    _positionSub = AudioService.player.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() {
          _position = p;
          AudioService.position = p;
        });
      }
    });

    _stateSub = AudioService.player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        final isPlayingNow = state == PlayerState.playing;
        setState(() {
          AudioService.isPlaying = isPlayingNow;
        });
      }
    });
  }

  Future<void> _generateWaveform() async {
    _setupAudio();
    setState(() => _isLoading = true);
    final waveformFile = File("./file.wav");

    try {
      final waveformStream = JustWaveform.extract(
        audioInFile: File(AudioService.getCurrentFilePath()),
        waveOutFile: waveformFile,
        zoom: const WaveformZoom.pixelsPerSecond(100),
      );

      Waveform? waveform;
      await for (final progress in waveformStream) {
        if (progress.waveform != null) {
          waveform = progress.waveform!;
        }
      }

      final samples = waveform!.data;
      final maxAmplitude = samples.reduce(max);
      final normalized = samples
          .map((s) => s / (maxAmplitude == 0 ? 1 : maxAmplitude))
          .toList();

      setState(() {
        _amplitudes = normalized;
        _isLoading = false;
      });
    } catch (e) {
      print(e);
      setState(() {
        _amplitudes = List.generate(100, (_) => 0.1);
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final currentTime = _formatDuration(_position);
    final totalTime = _formatDuration(_duration);

    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (details) {
        final box = context.findRenderObject() as RenderBox;
        final tapX = details.localPosition.dx;
        final width = box.size.width;
        final ratio = tapX / width;
        final newPosition = _duration * ratio;
        AudioService.player.seek(newPosition);
      },
      key: Key(AudioService.getCurrentFilePath()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _isLoading
              ? SizedBox(
                  height: 60,
                  width: widget.maxWidth == double.infinity
                      ? double.infinity
                      : widget.maxWidth,
                  child: const Center(child: CircularProgressIndicator()),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = min(constraints.maxWidth, widget.maxWidth);
                    final dotsCount = width ~/ 4;
                    List<double> dotsAmplitudes = [];

                    if (_amplitudes != null && _amplitudes!.isNotEmpty) {
                      final step = _amplitudes!.length / dotsCount;
                      for (int i = 0; i < dotsCount; i++) {
                        final index = (i * step).floor();
                        dotsAmplitudes.add(_amplitudes![
                            index.clamp(0, _amplitudes!.length - 1)]);
                      }
                    } else {
                      dotsAmplitudes = List.generate(dotsCount, (_) => 0.1);
                    }

                    return CustomPaint(
                      size: Size(width, 60),
                      painter: _WaveformPainter(
                        amplitudes: dotsAmplitudes,
                        progress: _duration.inMilliseconds == 0
                            ? 0
                            : _position.inMilliseconds /
                                _duration.inMilliseconds,
                        color: widget.dotColor,
                      ),
                    );
                  },
                ),
          const SizedBox(height: 8),
          Text(
            "$currentTime / $totalTime",
            style: TextStyle(
              color: widget.dotColor,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final double progress;
  final Color color;

  _WaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final spacing = size.width / amplitudes.length;

    for (int i = 0; i < amplitudes.length; i++) {
      final amp = amplitudes[i];
      final x = i * spacing;
      final barHeight = amp * size.height;
      final isPlayed = (i / amplitudes.length) <= progress;

      paint.color = isPlayed ? color : color.withOpacity(0.3);
      canvas.drawLine(
        Offset(x, size.height / 2 - barHeight / 2),
        Offset(x, size.height / 2 + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress || old.amplitudes != amplitudes;
}
