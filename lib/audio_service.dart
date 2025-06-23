import 'dart:ffi';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:uuid/uuid.dart';


class TrackData {
  final String path;
  final String title;
  final String artist;
  final BigInt uuid;

  static final _uuidGenerator = Uuid();

  TrackData({
    required this.path,
    required this.title,
    required this.artist,
  }) : uuid = _uuidToBigInt(_uuidGenerator.v4());

  static BigInt _uuidToBigInt(String uuidStr) {
    // Remove dashes, get 32 hex characters (128 bits)
    final hex = uuidStr.replaceAll('-', '');
    return BigInt.parse(hex, radix: 16);
  }
}

class AudioService {
  static final AudioPlayer player = AudioPlayer();
  static bool isPlaying = true;
  static Duration position = Duration.zero;
  static Duration duration = Duration.zero;
  static List<TrackData> audioFiles = [];
  static List<TrackData> allFiles = [];
  static int current_index = 1;
  static double volume =  1.0;
  static BigInt current_uuid = BigInt.from(-1);

  static String getCurrentFilePath(){
    return audioFiles[current_index].path;
  }

  static bool isPlayerInitialized() {
    try {
      AudioService.player;
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<void> play() async {
    isPlaying = true;
    await AudioService.player.resume();
  }

 static Future<void> playFile(String filePath) async {
    print("Play Audio File: $filePath");
    try {
      await AudioService.player.setSource(DeviceFileSource(filePath));
      play();
    } catch (e) {
      print("❌ Failed to play file: $e");
    }
  }

 static Future<void> pause() async {
    await AudioService.player.pause();
  }

 static Future<void> seek(Duration position) async {
    await AudioService.player.seek(position);
  }

 static Future<void> togglePlayPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  static void dispose() {
    AudioService.player.dispose();
  }
}
