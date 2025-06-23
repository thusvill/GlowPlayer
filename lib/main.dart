import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_media_metadata/flutter_media_metadata.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:player/audio_service.dart';
import 'package:uuid/uuid.dart';
import 'waveform_dots_slider.dart';
import 'package:image/image.dart' as img;
import "package:window_manager/window_manager.dart";
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dart_tags/dart_tags.dart';
import 'package:string_similarity/string_similarity.dart';

String _searchQuery = '';

Future<void> _saveFolderPath(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('music_folder_path', path);
}

final FocusNode _searchFocusNode = FocusNode();
bool _isTypingSearch = false;

Future<List<Color>> extractVibrantColors(Uint8List imageBytes,
    {int maxColors = 6}) async {
  final image = img.decodeImage(imageBytes);
  if (image == null) return [];

  final resized = img.copyResize(image, width: 100);
  final Map<int, int> colorFrequency = {};
  final Map<int, Color> reducedToColor = {};
  int totalCount = 0;
  int grayscaleCount = 0;

  int reduceColorDepth(img.Pixel pixel) {
    int r = pixel.r.toInt() >> 3;
    int g = pixel.g.toInt() >> 3;
    int b = pixel.b.toInt() >> 3;
    return (r << 10) | (g << 5) | b;
  }

  for (int y = 0; y < resized.height; y++) {
    for (int x = 0; x < resized.width; x++) {
      final pixel = resized.getPixel(x, y);
      if (pixel.a < 128) continue;

      final r = pixel.r.toInt(), g = pixel.g.toInt(), b = pixel.b.toInt();
      totalCount++;

      // Check for grayscale
      if ((r - g).abs() < 10 && (r - b).abs() < 10 && (g - b).abs() < 10) {
        grayscaleCount++;
      }

      final hsl = _rgbToHsl(r, g, b);
      final sat = hsl[1], light = hsl[2];

      // Only keep vibrant + dark colors
      if (sat < 0.5 || light > 0.35) continue;

      final reduced = reduceColorDepth(pixel);
      colorFrequency[reduced] = (colorFrequency[reduced] ?? 0) + 1;
      reducedToColor[reduced] = Color.fromARGB(255, r, g, b);
    }
  }

  final sorted = colorFrequency.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final List<Color> result = [];

  for (var entry in sorted) {
    final color = reducedToColor[entry.key]!;
    if (result.any((c) => _colorDistance(c, color) < 40)) continue;
    result.add(color);
    if (result.length >= maxColors) break;
  }

  final isMostlyGrayscale = grayscaleCount / (totalCount + 1) > 0.6;

  // Fallback to dark grayscale colors
  if (result.length < 2 || isMostlyGrayscale) {
    return [
      const Color(0xFF000000), // Pure black
      const Color(0xFF121212), // Very dark gray
      const Color(0xFF2C2C2C), // Deep gray
      const Color(0xFF3F3F3F), // Charcoal
    ].take(maxColors).toList();
  }

  if (result.length == 1) {
    result.add(const Color(0xFF2C2C2C));
  }

  return result.take(maxColors).toList();
}

double _luminance(Color c) {
  // Standard relative luminance formula
  return (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue) / 255.0;
}

// HSL conversion: returns [hue, saturation, lightness]
List<double> _rgbToHsl(int r, int g, int b) {
  final rf = r / 255.0;
  final gf = g / 255.0;
  final bf = b / 255.0;

  final max = [rf, gf, bf].reduce((a, b) => a > b ? a : b);
  final min = [rf, gf, bf].reduce((a, b) => a < b ? a : b);
  final delta = max - min;

  double h = 0.0;
  double s = 0.0;
  double l = (max + min) / 2.0;

  if (delta != 0) {
    s = delta / (1 - (2 * l - 1).abs());
    if (max == rf) {
      h = ((gf - bf) / delta) % 6;
    } else if (max == gf) {
      h = ((bf - rf) / delta) + 2;
    } else {
      h = ((rf - gf) / delta) + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
  }

  return [h, s, l];
}

// Color distance to avoid duplicates
double _colorDistance(Color a, Color b) {
  return ((a.red - b.red).abs() +
          (a.green - b.green).abs() +
          (a.blue - b.blue).abs())
      .toDouble();
}

String getSystemMusicFolder() {
  if (Platform.isMacOS || Platform.isLinux) {
    final home = Platform.environment['HOME'];
    return '$home/Music';
  } else if (Platform.isWindows) {
    final userProfile = Platform.environment['USERPROFILE'];
    return '$userProfile\\Music';
  } else {
    throw UnsupportedError('Unsupported platform for system Music folder');
  }
}

String _formatDuration(Duration d) {
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  final minutes = twoDigits(d.inMinutes.remainder(60));
  final seconds = twoDigits(d.inSeconds.remainder(60));
  return "$minutes:$seconds";
}

class _NoArrowKeyFocusTraversalPolicy extends WidgetOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (!_isTypingSearch) {
      if (direction == TraversalDirection.left ||
          direction == TraversalDirection.right ||
          direction == TraversalDirection.up ||
          direction == TraversalDirection.down) {
        return false;
      }
    }
    return super.inDirection(currentNode, direction);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(420, 735),
    minimumSize: Size(364, 735),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden, // hides native macOS title bar
    skipTaskbar: false,
    fullScreen: false,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const MyApp());
}

bool _isSidePanelOpen = true;
bool _manuallyToggled = false;
bool _lastWidthWasNarrow = false;
bool keymap = false;
void showBlurredPopup(BuildContext context) {
  if (keymap) {
    return;
  }
  keymap = true;
  showDialog(
    context: context,
    barrierDismissible: true,
    barrierColor:
        Colors.black.withOpacity(0.3), // semi-transparent dark overlay
    builder: (BuildContext context) {
      return WillPopScope(
          onWillPop: () async {
            keymap = false; // Reset on back button
            return true;
          },
          child: Dialog(
            backgroundColor:
                Colors.white.withOpacity(0.2), // translucent dialog bg
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: EdgeInsets.all(20),
                  constraints: BoxConstraints(maxWidth: 450, maxHeight: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Keymap",
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 20),
                      // Your keymap content here, example:
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              keyUsageRow("@",
                                  "Type '@' on Searchbar for filter by artists"),
                              keyUsageRow("L", "Change Loop type"),
                              keyUsageRow("M", "Mute/Unmute"),
                              keyUsageRow("→", "Next Track"),
                              keyUsageRow("←", "Previous Track"),
                              keyUsageRow("↑", "Volume up"),
                              keyUsageRow("↓", "Volume down"),
                              keyUsageRow("Space", "Play/Pause"),
                              keyUsageRow("Esc", "Open Menu"),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text("Close",
                            style: TextStyle(
                                color:
                                    const Color.fromARGB(238, 255, 255, 255))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ));
    },
  );
}

Widget keyUsageRow(String key, String usage) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6.0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            key,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
              fontFamily: 'monospace',
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            usage,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
            ),
          ),
        ),
      ],
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Widget build(BuildContext context) {
    return MaterialApp(
      builder: (context, child) {
        return FocusTraversalGroup(
          policy: _NoArrowKeyFocusTraversalPolicy(),
          child: child!,
        );
      },
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: MeshAudioVisualizer(),
    );
  }
}

class MeshAudioVisualizer extends StatefulWidget {
  const MeshAudioVisualizer({super.key});

  @override
  State<MeshAudioVisualizer> createState() => _MeshAudioVisualizerState();
}

class _MeshAudioVisualizerState extends State<MeshAudioVisualizer>
    with TickerProviderStateMixin {
  late MeshGradientController _meshController;
  late Ticker _ticker;
  final List<Offset> _velocities = [];
  String? _songTitle;
  String? _artist;
  String? _filePath;
  String? _musicFolder;
  Uint8List? _artworkBytes;
  int loop_type = 0; //0 no loop, 1 loop current track, 2 loop list

  final _random = Random();
  Future<void> _loadFolderPath() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('music_folder_path');
    if (savedPath != null && savedPath.isNotEmpty) {
      setState(() {
        _musicFolder = savedPath;
        print("Found folderpath: $savedPath");
        _loadAudioFiles();
      });
    }
  }

  void _applySearch() {
    final query = _searchQuery.trim().toLowerCase();
    BigInt prev_uuid = AudioService.current_uuid;

    if (query.isEmpty) {
      AudioService.audioFiles = AudioService.allFiles;
      print("Search query is empty");
      
    } else {
      final isArtistSearch = query.startsWith('@');
      final searchTerm = isArtistSearch ? query.substring(1) : query;

      AudioService.audioFiles = AudioService.allFiles.where((track) {
        final target = isArtistSearch
            ? track.artist.toLowerCase()
            : track.title.toLowerCase();


        final similarity =
            StringSimilarity.compareTwoStrings(target, searchTerm);


        final containsMatch = target.contains(searchTerm);

        return containsMatch || similarity > 0.9;
      }).toList();

      if(AudioService.audioFiles.isEmpty){
        AudioService.audioFiles = AudioService.allFiles;
      }
    }

    if (AudioService.audioFiles
            .indexWhere((entity) => entity.uuid == prev_uuid) !=
        -1) {
      AudioService.current_index = AudioService.audioFiles
          .indexWhere((entity) => entity.uuid == prev_uuid);
      print(
          "Track index changed with UUID: ${prev_uuid} to index: ${AudioService.current_index}");
    } else {
      AudioService.current_index = 0;
      print(
          "Track index changed with UUID: ${prev_uuid} to index: ${AudioService.current_index}");
    }

    setState(() {});
  }

  @override
  void initState() {
    super.initState();

    _searchFocusNode.addListener(() {
      setState(() {
        _isTypingSearch = _searchFocusNode.hasFocus;
      });
    });

    HardwareKeyboard.instance.addHandler(_handleKey);
    _loadFolderPath();
    //_loadAudioFiles();

    final initialColors = [
      Colors.black,
      Colors.black,
      Colors.black,
      Colors.black,
      Colors.black,
      Colors.grey,
    ];

    _meshController = MeshGradientController(
      points: _initialPoints(initialColors),
      vsync: this,
    );

    // Assign random velocities
    _velocities.addAll(List.generate(
      _meshController.points.value.length,
      (_) => Offset(
        _randVelocity(),
        _randVelocity(),
      ),
    ));

    _ticker = createTicker(_updatePoints)..start();

    AudioService.player.onPlayerComplete.listen((event) {
      print("Audio finished!");
      if (AudioService.audioFiles.isEmpty) return;
      if (loop_type == 0) {
        AudioService.pause();
        return;
      } else if (loop_type == 1) {
        AudioService.isPlaying = true;
        _pickAudioFile(_filePath!);
      } else if (loop_type == 2) {
        AudioService.current_index++;
        if (AudioService.current_index >= AudioService.audioFiles.length) {
          AudioService.current_index = 0;
        }
        print("Playing next file from index : ${AudioService.current_index}");
        AudioService.isPlaying = true;
        _pickAudioFile(
            AudioService.audioFiles[AudioService.current_index].path);
      }
    });
  }

  Future<void> _pickMusicFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      final dir = Directory(selectedDirectory);
      final files = dir.listSync(recursive: true).where((file) {
        final ext = file.path.split('.').last.toLowerCase();
        return ['mp3', 'm4a', 'flac'].contains(ext);
      });

      final tagProcessor = TagProcessor();
      List<TrackData> loadedTracks = [];

      for (var file in files) {
        try {
          final f = File(file.path);
          final tags = await tagProcessor.getTagsFromByteArray(f.readAsBytes());

          String title = '';
          String artist = '';

          for (var tag in tags) {
            title = tag.tags['title']?.toString() ?? '';
            artist = tag.tags['artist']?.toString() ?? '';
          }

          if (title.isEmpty) {
            title = file.path.split(Platform.pathSeparator).last;
          }

          loadedTracks.add(TrackData(
            path: file.path,
            title: title,
            artist: artist,
          ));
        } catch (_) {
          // fallback to filename if metadata reading fails
          final name = file.path.split(Platform.pathSeparator).last;
          loadedTracks.add(TrackData(path: file.path, title: name, artist: ''));
        }
      }

      setState(() {
        AudioService.allFiles = loadedTracks;
        _applySearch(); // Apply current search to new list
      });
    }
  }

  double prev_vol = 0.0;
  bool _handleKey(KeyEvent event) {
    if (_isTypingSearch) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          if (!keymap) {
            _searchFocusNode.unfocus();
          } else {
            Navigator.of(context, rootNavigator: true).pop();
            keymap = false;
          }
        });
        return true;
      }
    }
    if (!_isTypingSearch) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _manuallyToggled = true;
          _isSidePanelOpen = !_isSidePanelOpen;
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.keyK) {
        setState(() {
          if (keymap) {
            // If dialog is open, close it
            Navigator.of(context, rootNavigator: true).pop();
            keymap = false;
          } else {
            // If dialog is closed, open it
            showBlurredPopup(context);
          }
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        setState(() {
          _playPreviousTrack();
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        setState(() {
          _playNextTrack();
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          if (AudioService.volume < 1) {
            AudioService.volume += 0.1;
            AudioService.player.setVolume(AudioService.volume);
          }
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          if (AudioService.volume > 0) {
            AudioService.volume -= 0.1;
            AudioService.player.setVolume(AudioService.volume);
          }
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter) {
        setState(() {
          _searchFocusNode.requestFocus();
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.space) {
        setState(() {
          AudioService.togglePlayPause();
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.physicalKey == PhysicalKeyboardKey.keyM) {
        setState(() {
          if (AudioService.volume > 0) {
            prev_vol = AudioService.volume;
            AudioService.volume = 0.0;
            AudioService.player.setVolume(AudioService.volume);
          } else {
            AudioService.volume = prev_vol;
            AudioService.player.setVolume(AudioService.volume);
          }
        });
        return true;
      }
      if (event is KeyDownEvent &&
          event.physicalKey == PhysicalKeyboardKey.keyL) {
        setState(() {
          if (loop_type == 2) {
            loop_type = 0;
          } else {
            loop_type++;
          }
        });
        return true;
      }
    }
    return false;
  }

  Future<void> _loadAudioFiles() async {
    final musicPath = _musicFolder;
    final musicDir = Directory(musicPath!);

    final audioExtensions = ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'];

    if (!musicDir.existsSync()) {
      print("❌ Music folder not found at: $musicPath");
      return;
    }
    print("📂 Loading files from: $musicDir");

    final files = musicDir
        .listSync(recursive: true)
        .where((file) =>
            file is File &&
            audioExtensions.contains(file.path.split('.').last.toLowerCase()))
        .cast<File>()
        .toList();

    final tagProcessor = TagProcessor();
    List<TrackData> loadedTracks = [];

    for (var file in files) {
      try {
        final tags =
            await tagProcessor.getTagsFromByteArray(file.readAsBytes());

        String title = '';
        String artist = '';

        if (tags.isNotEmpty) {
          final tag = tags.first;
          title = tag.tags['title']?.toString() ?? '';
          artist = tag.tags['artist']?.toString() ?? '';
        }

        if (title.isEmpty) {
          title = file.path.split(Platform.pathSeparator).last;
        }

        AudioService.allFiles = loadedTracks;

        loadedTracks.add(TrackData(
          path: file.path,
          title: title,
          artist: artist,
        ));
      } catch (e) {
        print("⚠️ Failed to read tags from ${file.path}: $e");
        final fallbackName = file.path.split(Platform.pathSeparator).last;
        loadedTracks
            .add(TrackData(path: file.path, title: fallbackName, artist: ''));
      }
    }

    setState(() {
      AudioService.audioFiles = loadedTracks;
    });

    print("✅ Loaded ${loadedTracks.length} audio tracks.");
  }

  double _randVelocity() {
    return (_random.nextDouble() * 0.01 + 0.002) *
        (_random.nextBool() ? 1 : -1);
  }

  void _updatePoints(Duration _) {
    final points = _meshController.points.value;
    final updated = <MeshGradientPoint>[];

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final v = _velocities[i];
      Offset newPos = p.position + v;

      // Bounce off edges
      if (newPos.dx < 0 || newPos.dx > 1) {
        _velocities[i] = Offset(-v.dx, v.dy);
        newPos = p.position + _velocities[i];
      }
      if (newPos.dy < 0 || newPos.dy > 1) {
        _velocities[i] = Offset(_velocities[i].dx, -v.dy);
        newPos = p.position + _velocities[i];
      }

      updated.add(MeshGradientPoint(position: newPos, color: p.color));
    }

    _meshController.points.value = updated;
  }

  List<MeshGradientPoint> _initialPoints(List<Color> cols) {
    final l = cols.length;
    return cols.asMap().entries.map((e) {
      final i = e.key;
      return MeshGradientPoint(
        position: Offset(i / l, 0.5),
        color: e.value,
      );
    }).toList();
  }

  Future<void> _pickAudioFile(String path) async {
    final metadata = await MetadataRetriever.fromFile(File(path));

    AudioService.current_index =
        AudioService.audioFiles.indexWhere((entity) => entity.path == path);
    AudioService.current_uuid = AudioService
        .audioFiles[
            AudioService.audioFiles.indexWhere((entity) => entity.path == path)]
        .uuid;

    setState(() {
      _songTitle = metadata.trackName;
      _artist = metadata.trackArtistNames?.join(", ");
      _filePath = path;
    });

    final artwork = metadata.albumArt;
    if (artwork != null) {
      setState(() {
        _artworkBytes = artwork;
      });

      final colors = await extractVibrantColors(artwork, maxColors: 6);
      if (colors.isNotEmpty) {
        final newPoints = _initialPoints(colors);
        _meshController.points.value = newPoints;

        _velocities.clear();
        _velocities.addAll(List.generate(
          newPoints.length,
          (_) => Offset(
            _randVelocity(),
            _randVelocity(),
          ),
        ));
      }
    } else {
      setState(() {
        _artworkBytes = null;
      });
    }
    print("Button Clocked on ${path}");
    AudioService.playFile(path);
    AudioService.play();
  }

  @override
  void dispose() {
    _meshController.dispose();
    _ticker.dispose();
    _searchFocusNode.dispose();
    AudioService.dispose();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  IconData get _volumeIcon {
    if (AudioService.volume == 0) return Icons.volume_off;
    if (AudioService.volume < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }

  IconData getLoopIcon() {
    if (!AudioService.isPlaying) {
      return Icons.cancel_outlined;
    } else {
      // Player is playing, show pause icon but modify by loop_type
      switch (loop_type) {
        case 0:
          return Icons.cancel_outlined; // No loop
        case 1:
          return Icons.repeat_one_outlined; // Loop track
        case 2:
          return Icons.repeat_outlined; // Loop playlist
        default:
          return Icons.cancel_outlined;
      }
    }
  }

  bool _hovering = false;

  void _playPreviousTrack() {
    AudioService.current_index--;
    if (AudioService.current_index >= 0) {
      _pickAudioFile(AudioService.getCurrentFilePath());
    } else {
      AudioService.current_index = AudioService.audioFiles.length;
      _pickAudioFile(AudioService.getCurrentFilePath());
    }
  }

  void _playNextTrack() {
    AudioService.current_index++;
    if (AudioService.current_index < AudioService.audioFiles.length) {
      _pickAudioFile(AudioService.getCurrentFilePath());
    } else {
      AudioService.current_index = 0;
      _pickAudioFile(AudioService.getCurrentFilePath());
    }
  }

  Widget build(BuildContext context) {
    return Scaffold(
      appBar: null,
      backgroundColor: const Color.fromARGB(0, 0, 0, 0),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final bool isNarrow = width < 700;
          if (!isNarrow) {
            _manuallyToggled = false;
          }
          if (!_manuallyToggled) {
            if (isNarrow && _isSidePanelOpen) {
              Future.microtask(() {
                if (mounted) {
                  setState(() {
                    _isSidePanelOpen = false;
                    _lastWidthWasNarrow = true;
                  });
                }
              });
            } else if (!isNarrow && !_isSidePanelOpen && _lastWidthWasNarrow) {
              Future.microtask(() {
                if (mounted) {
                  setState(() {
                    _isSidePanelOpen = true;
                    _lastWidthWasNarrow = false;
                  });
                }
              });
            }
          }

          return Stack(
            children: [
              Positioned.fill(
                child: MeshGradient(
                  controller: _meshController,
                  options: MeshGradientOptions(),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: CircleBorder(),
                    padding: EdgeInsets.all(12),
                    backgroundColor: const Color.fromARGB(
                        0, 255, 255, 255), // Customize color if you want
                    elevation: 4,
                  ),
                  onPressed: () => showBlurredPopup(context),
                  child: Icon(Icons.keyboard, color: Colors.white),
                ),
              ),

              Column(
                children: [
                  if (AudioService.audioFiles.length == 0)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'No Audio files found',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: _pickMusicFolder,
                            icon: const Icon(Icons.folder_open),
                            label: const Text("Pick Music Folder"),
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: Colors.white.withOpacity(0.08),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Main content
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(32),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_artworkBytes != null) ...[
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final double size =
                                        (constraints.maxWidth / 2.3)
                                            .clamp(260.0, 800.0);

                                    return Container(
                                      width: size,
                                      height: size,
                                      decoration: BoxDecoration(
                                        boxShadow: [
                                          BoxShadow(
                                            color:
                                                Colors.black.withOpacity(0.5),
                                            blurRadius: 50,
                                            offset: const Offset(1, 8),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.memory(_artworkBytes!,
                                            fit: BoxFit.cover),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 20),
                              ],
                              if (_songTitle != null) ...[
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    // Calculate base font sizes based on width, with min/max clamp
                                    final double titleFontSize =
                                        (constraints.maxWidth / 15)
                                            .clamp(32, 64);
                                    final double artistFontSize =
                                        (constraints.maxWidth / 30)
                                            .clamp(5, 25);

                                    return Column(
                                      children: [
                                        Text(
                                          _songTitle!,
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: titleFontSize,
                                            fontWeight: FontWeight.w700,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        if (_artist != null)
                                          Text(
                                            _artist!,
                                            style: TextStyle(
                                              color: Colors.white70,
                                              fontSize: artistFontSize,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                              if (_filePath != null) ...[
                                const SizedBox(height: 24),
                                WaveformDotsSlider(
                                  key: ValueKey(
                                      AudioService.getCurrentFilePath()),
                                  dotColor: Colors.white,
                                  maxWidth: 800,
                                ),
                                //Controls
                                Row(
                                  mainAxisSize: MainAxisSize
                                      .min, // shrink-wrap horizontally
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.fast_rewind_rounded,
                                        color: Colors.white,
                                        size: 25,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _playPreviousTrack();
                                        });
                                      },
                                    ),
                                    IconButton(
                                      key: ValueKey(
                                          AudioService.isPlaying.toString()),
                                      icon: Icon(
                                        AudioService.isPlaying
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                        color: Colors.white,
                                        size: 30,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          AudioService.togglePlayPause();
                                        });
                                      },
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        Icons.fast_forward_rounded,
                                        color: Colors.white,
                                        size: 25,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _playNextTrack();
                                        });
                                      },
                                    ),
                                    const SizedBox(width: 5),
                                    IconButton(
                                      key: ValueKey(loop_type),
                                      icon: Icon(
                                        getLoopIcon(),
                                        color: Colors.white,
                                        size: 25,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          if (loop_type == 2) {
                                            loop_type = 0;
                                          } else {
                                            loop_type++;
                                          }
                                          print("Loop state $loop_type");
                                        });
                                      },
                                    ),
                                    MouseRegion(
                                      onEnter: (_) =>
                                          setState(() => _hovering = true),
                                      onExit: (_) =>
                                          setState(() => _hovering = false),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(_volumeIcon,
                                                color: Colors.white),
                                            onPressed: () {
                                              setState(() {
                                                if (AudioService.volume > 0) {
                                                  AudioService.volume = 0;
                                                } else {
                                                  AudioService.volume = 1.0;
                                                }
                                                AudioService.player.setVolume(
                                                    AudioService.volume);
                                              });
                                            },
                                          ),
                                          AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 200),
                                            curve: Curves.easeOut,
                                            width: _hovering ? 190 : 0,
                                            child: AnimatedOpacity(
                                              duration: const Duration(
                                                  milliseconds: 200),
                                              opacity: _hovering ? 1.0 : 0.0,
                                              child: Slider(
                                                key: Key(AudioService.volume
                                                    .toString()),
                                                value: AudioService.volume,
                                                min: 0,
                                                max: 1,
                                                onChanged: (val) {
                                                  setState(() {
                                                    AudioService.volume = val;
                                                    AudioService.player
                                                        .setVolume(AudioService
                                                            .volume);
                                                  });
                                                },
                                                activeColor: Colors.white,
                                                inactiveColor: Colors.white54,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  ],
                                )
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // Side panel (floating)

              AnimatedPositioned(
                //key: Key(_isSidePanelOpen.toString()),
                top: 0,
                bottom: 0,
                left: _isSidePanelOpen ? 0 : -260,
                width: 250,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: ClipRRect(
                  // Clip the blur to panel only
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        border: const Border(
                          right: BorderSide(color: Colors.white12),
                        ),
                      ),
                      child: Column(
                        children: [
                          SizedBox(height: 20),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                //const SizedBox(height: 90),
                                const Icon(Icons.library_music_rounded,
                                    color: Colors.white70, size: 18),
                                const Text(
                                  "Music Library",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: () => setState(() {
                                    _isSidePanelOpen = false;
                                    _manuallyToggled = true;
                                  }),
                                  icon: const Icon(Icons.close,
                                      color: Colors.white54, size: 18),
                                  tooltip: "Close",
                                ),
                              ],
                            ),
                          ),
                          // TextField(
                          //   focusNode: _searchFocusNode,
                          //   decoration: InputDecoration(
                          //     labelText: 'Search tracks...',
                          //     prefixIcon: Icon(Icons.search),
                          //     border: OutlineInputBorder(),
                          //   ),
                          //   onChanged: (value) {
                          //     _searchQuery = value;
                          //     _applySearch();
                          //   },
                          // ),
                          SizedBox(
                            width: 220, // Set your desired width here
                            child: TextField(
                              focusNode: _searchFocusNode,
                              decoration: InputDecoration(
                                labelText: 'Search tracks...',
                                prefixIcon:
                                    Icon(Icons.search, color: Colors.white70),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.1),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                      color: Colors.white70, width: 1.5),
                                ),
                                labelStyle: TextStyle(color: Colors.white70),
                                contentPadding: EdgeInsets.symmetric(
                                    vertical: 12, horizontal: 16),
                              ),
                              style: TextStyle(color: Colors.white),
                              cursorColor: Colors.white70,
                              onChanged: (value) {
                                _searchQuery = value;
                                _applySearch();
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: ElevatedButton.icon(
                              onPressed: _pickMusicFolder,
                              icon: const Icon(Icons.folder_open),
                              label: const Text("Pick Music Folder"),
                              style: ElevatedButton.styleFrom(
                                elevation: 0,
                                backgroundColor: Colors.white.withOpacity(0.08),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12, horizontal: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                            ),
                          ),
                          //const SizedBox(height: 12),
                          Expanded(
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              itemCount: AudioService.audioFiles.length,
                              itemBuilder: (context, index) {
                                final file = AudioService.audioFiles[index];
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 3),
                                  child: ElevatedButton(
                                    onPressed: () {
                                      _pickAudioFile(file.path);
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          Colors.white.withOpacity(0.06),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10, horizontal: 12),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        file.title
                                            .trim()
                                            .replaceAll('\n', '')
                                            .replaceAll('\r', ''),
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Toggle button
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                top: 60,
                left: _isSidePanelOpen ? 250 : 0,
                child: _isSidePanelOpen
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        onTap: () {
                          setState(() {
                            _isSidePanelOpen = !_isSidePanelOpen;
                            _manuallyToggled = true;
                          });
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            width: 24,
                            height: 40,
                            color: Colors.transparent,
                            child: Center(
                              child: Icon(
                                Icons.more_vert_outlined,
                                color: Colors.white.withOpacity(0.6),
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
