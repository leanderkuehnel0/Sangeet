//

import 'dart:io';

import 'package:sangeet/Helpers/mediaitem_converter.dart';
import 'package:sangeet/Screens/Player/audioplayer.dart';
import 'package:sangeet/Services/youtube_services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

// ignore: avoid_classes_with_only_static_members
class PlayerInvoke {
  static final AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();

  static Future<void> init({
    required List songsList,
    required int index,
    bool fromMiniplayer = false,
    bool? isOffline,
    bool recommend = true,
    bool fromDownloads = false,
    bool shuffle = false,
    String? playlistBox,
  }) async {
    final int globalIndex = index < 0 ? 0 : index;
    bool? offline = isOffline;
    final List finalList = songsList.toList();
    if (shuffle) finalList.shuffle();
    if (offline == null) {
      if (audioHandler.mediaItem.value?.extras!['url'].startsWith('http')
          as bool) {
        offline = false;
      } else {
        offline = true;
      }
    } else {
      offline = offline;
    }

    if (!fromMiniplayer) {
      if (!Platform.isAndroid) {
        // Don't know why but it fixes the playback issue with iOS Side
        audioHandler.stop();
      }
      if (offline) {
        fromDownloads
            ? setDownValues(finalList, globalIndex)
            : (Platform.isWindows || Platform.isLinux)
                ? setOffDesktopValues(finalList, globalIndex)
                : setOffValues(finalList, globalIndex);
      } else {
        setValues(
          finalList,
          globalIndex,
          recommend: recommend,
          playlistBox: playlistBox,
        );
      }
    }
  }

  static Future<MediaItem> setTags(
    SongModel response,
    Directory tempDir,
  ) async {
    String playTitle = response.title;
    playTitle == ''
        ? playTitle = response.displayNameWOExt
        : playTitle = response.title;
    String playArtist = response.artist!;
    playArtist == '<unknown>'
        ? playArtist = 'Unknown'
        : playArtist = response.artist!;

    final String playAlbum = response.album!;
    final int playDuration = response.duration ?? 180000;
    final String imagePath = '${tempDir.path}/${response.displayNameWOExt}.jpg';

    final MediaItem tempDict = MediaItem(
      id: response.id.toString(),
      album: playAlbum,
      duration: Duration(milliseconds: playDuration),
      title: playTitle.split('(')[0],
      artist: playArtist,
      genre: response.genre,
      artUri: Uri.file(imagePath),
      extras: {
        'url': response.data,
        'date_added': response.dateAdded,
        'date_modified': response.dateModified,
        'size': response.size,
        'year': response.getMap['year'],
      },
    );
    return tempDict;
  }

  static void setOffDesktopValues(List response, int index) {
    getTemporaryDirectory().then((tempDir) async {
      final File file = File('${tempDir.path}/cover.jpg');
      if (!await file.exists()) {
        final byteData = await rootBundle.load('assets/cover.jpg');
        await file.writeAsBytes(
          byteData.buffer
              .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
        );
      }
      final List<MediaItem> queue = [];
      queue.addAll(
        response.map(
          (song) => MediaItem(
            id: song['id'].toString(),
            album: song['album'].toString(),
            artist: song['artist'].toString(),
            duration: Duration(
              seconds: int.parse(
                (song['duration'] == null || song['duration'] == 'null')
                    ? '180'
                    : song['duration'].toString(),
              ),
            ),
            title: song['title'].toString(),
            artUri: Uri.file(file.path),
            genre: song['genre'].toString(),
            extras: {
              'url': song['path'].toString(),
              'subtitle': song['subtitle'],
              'quality': song['quality'],
            },
          ),
        ),
      );
      updateNplay(queue, index);
    });
  }

  static void setOffValues(List response, int index) {
    getTemporaryDirectory().then((tempDir) async {
      final File file = File('${tempDir.path}/cover.jpg');
      if (!await file.exists()) {
        final byteData = await rootBundle.load('assets/cover.jpg');
        await file.writeAsBytes(
          byteData.buffer
              .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
        );
      }
      final List<MediaItem> queue = [];
      for (int i = 0; i < response.length; i++) {
        queue.add(
          await setTags(response[i] as SongModel, tempDir),
        );
      }
      updateNplay(queue, index);
    });
  }

  static void setDownValues(List response, int index) {
    final List<MediaItem> queue = [];
    queue.addAll(
      response.map(
        (song) => MediaItemConverter.downMapToMediaItem(song as Map),
      ),
    );
    updateNplay(queue, index);
  }

  static void refreshYtLink2({
    required Map playItem,
    String? playlistBox,
    required String cached,
  }) {
    YouTubeServices().refreshLink(playItem['id'].toString()).then(
      (newData) {
        Logger.root.info('received new link for ${playItem["title"]}');
        if (newData != null) {
          playItem['url'] = newData['url'];
          playItem['duration'] = newData['duration'];
          playItem['expire_at'] = newData['expire_at'];
          Hive.box('ytlinkcache').put(
            newData['id'],
            {
              'url': newData['url'],
              'expire_at': newData['expire_at'],
              'cached': cached,
            },
          );
          if (playlistBox != null) {
            Logger.root.info('linked with playlist $playlistBox');
            if (Hive.box(playlistBox).containsKey(playItem['id'])) {
              Logger.root.info('updating item in playlist $playlistBox');
              Hive.box(playlistBox).put(
                playItem['id'],
                playItem,
              );
            }
          }
        }
      },
    );
  }

  static void refreshYtLink(Map playItem, String? playlistBox) {
    final bool cacheSong =
        Hive.box('settings').get('cacheSong', defaultValue: true) as bool;
    final int expiredAt = int.parse((playItem['expire_at'] ?? '0').toString());
    if ((DateTime.now().millisecondsSinceEpoch ~/ 1000) + 350 > expiredAt) {
      Logger.root.info('youtube link expired for ${playItem["title"]}');
      if (Hive.box('ytlinkcache').containsKey(playItem['id'])) {
        final Map cache = Hive.box('ytlinkcache').get(playItem['id']) as Map;
        final int expiredAt = int.parse((cache['expire_at'] ?? '0').toString());
        final String wasCacheEnabled = cache['cached'].toString();
        if ((DateTime.now().millisecondsSinceEpoch ~/ 1000) + 350 > expiredAt &&
            wasCacheEnabled != 'true') {
          Logger.root
              .info('youtube link expired in cache for ${playItem["title"]}');
          refreshYtLink2(
            playItem: playItem,
            playlistBox: playlistBox,
            cached: cacheSong.toString(),
          );
        } else {
          Logger.root
              .info('youtube link found in cache for ${playItem["title"]}');
          playItem['url'] = cache['url'];
          playItem['expire_at'] = cache['expire_at'];
          if (playlistBox != null) {
            Logger.root.info('linked with playlist $playlistBox');
            if (Hive.box(playlistBox).containsKey(playItem['id'])) {
              Logger.root.info('updating item in playlist $playlistBox');
              Hive.box(playlistBox).put(
                playItem['id'],
                playItem,
              );
            }
          }
        }
      } else {
        refreshYtLink2(
          playItem: playItem,
          playlistBox: playlistBox,
          cached: cacheSong.toString(),
        );
      }
    }
  }

  static void setValues(
    List response,
    int index, {
    bool recommend = true,
    String? playlistBox,
  }) {
    final List<MediaItem> queue = [];
    final Map playItem = response[index] as Map;
    final Map? nextItem =
        index == response.length - 1 ? null : response[index + 1] as Map;
    if (playItem['genre'] == 'YouTube') {
      refreshYtLink(playItem, playlistBox);
    }
    if (nextItem != null && nextItem['genre'] == 'YouTube') {
      refreshYtLink(nextItem, playlistBox);
    }
    queue.addAll(
      response.map(
        (song) => MediaItemConverter.mapToMediaItem(
          song as Map,
          autoplay: recommend,
          playlistBox: playlistBox,
        ),
      ),
    );
    updateNplay(queue, index);
  }

  static Future<void> updateNplay(List<MediaItem> queue, int index) async {
    await audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
    await audioHandler.updateQueue(queue);
    await audioHandler.skipToQueueItem(index);
    await audioHandler.play();
    final String repeatMode =
        Hive.box('settings').get('repeatMode', defaultValue: 'None').toString();
    final bool enforceRepeat =
        Hive.box('settings').get('enforceRepeat', defaultValue: false) as bool;
    if (enforceRepeat) {
      switch (repeatMode) {
        case 'None':
          audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
          break;
        case 'All':
          audioHandler.setRepeatMode(AudioServiceRepeatMode.all);
          break;
        case 'One':
          audioHandler.setRepeatMode(AudioServiceRepeatMode.one);
          break;
        default:
          break;
      }
    } else {
      audioHandler.setRepeatMode(AudioServiceRepeatMode.none);
      Hive.box('settings').put('repeatMode', 'None');
    }
  }
}
