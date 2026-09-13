import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../player/domain/models/song.dart';
import '../../../player/domain/services/lyric_parser.dart';

class TagWriteService {
  static const _channel = MethodChannel('com.mintmusic/tag_writer');

  Future<void> processSongFiles(
    String songPath,
    Song songInfo, {
    required bool basicInfo,
    required bool cover,
    required bool lyrics,
    required bool downloadLyrics,
    required String lyricFormat,
  }) async {
    final file = File(songPath);
    if (!await file.exists()) return;
    if (!_isAudioFile(songPath)) return;

    debugPrint('[TagWriteService] processSongFiles: path=$songPath, basicInfo=$basicInfo, cover=$cover, lyrics=$lyrics, downloadLyrics=$downloadLyrics, lyricFormat=$lyricFormat');

    final baseName = _baseNameWithoutExt(songPath);
    final dirName = file.parent.path;
    String? coverPath;
    Uint8List? coverBytes;

    try {
      if (cover && songInfo.coverUrl != null && songInfo.coverUrl!.isNotEmpty) {
        try {
          final coverRes = await Dio().get<List<int>>(
            songInfo.coverUrl!,
            options: Options(responseType: ResponseType.bytes, receiveTimeout: const Duration(seconds: 15)),
          );
          final rawBytes = coverRes.data;
          if (rawBytes != null && rawBytes.isNotEmpty) {
            coverBytes = Uint8List.fromList(rawBytes);
            final coverExt = _resolveCoverExt(
              songInfo.coverUrl!,
              coverRes.headers.value('content-type'),
            );
            coverPath = '$dirName${Platform.pathSeparator}$baseName$coverExt';
            await File(coverPath).writeAsBytes(coverBytes!);
            debugPrint('[TagWriteService] 封面已下载: $coverPath (${coverBytes!.length} bytes)');
          }
        } catch (e) {
          debugPrint('[TagWriteService] 下载封面失败: $e');
          coverPath = null;
          coverBytes = null;
        }
      }

      if (downloadLyrics && songInfo.lrc != null && songInfo.lrc!.isNotEmpty) {
        try {
          final lrcPath = '$dirName${Platform.pathSeparator}$baseName.lrc';
          final lrcContent = lyricFormat == 'word-by-word'
              ? _convertLrcFormat(songInfo.lrc!)
              : _convertToStandardLrc(songInfo.lrc!);
          if (lrcContent.isNotEmpty) {
            await File(lrcPath).writeAsString(lrcContent);
            debugPrint('[TagWriteService] 歌词文件已保存: $lrcPath');
          }
        } catch (e) {
          debugPrint('[TagWriteService] 单独下载歌词文件失败: $e');
        }
      }

      String? lrcToEmbed;
      if (lyrics && songInfo.lrc != null && songInfo.lrc!.isNotEmpty) {
        lrcToEmbed = lyricFormat == 'word-by-word'
            ? _convertLrcFormat(songInfo.lrc!)
            : _convertToStandardLrc(songInfo.lrc!);
      }

      // 对齐 CeruMusic: basic info 始终写入（title, artist, album, albumArtist）
      final useBasicInfo = basicInfo;
      final useArtwork = cover && coverBytes != null;

      final titleStr = useBasicInfo
          ? (songInfo.title.isNotEmpty ? songInfo.title : '未知曲目')
          : null;
      final artistStr = useBasicInfo
          ? (songInfo.artist.isNotEmpty ? songInfo.artist : '未知艺术家')
          : null;
      final albumStr = useBasicInfo
          ? (songInfo.album.isNotEmpty ? songInfo.album : '未知专辑')
          : null;
      final albumArtistStr = useBasicInfo
          ? (songInfo.artist.isNotEmpty ? songInfo.artist : '未知艺术家')
          : null;

      if (useArtwork) {
        debugPrint('[TagWriteService] 写入标签+封面: title=$titleStr, artist=$artistStr, album=$albumStr, hasLyrics=${lrcToEmbed != null}, artworkSize=${coverBytes?.length}');
        await _writeTagsAndArtwork(
          songPath,
          title: titleStr,
          artist: artistStr,
          album: albumStr,
          albumArtist: albumArtistStr,
          lyrics: lrcToEmbed,
          artwork: coverBytes!,
        );
      } else if (useBasicInfo || lrcToEmbed != null) {
        debugPrint('[TagWriteService] 写入标签: title=$titleStr, artist=$artistStr, album=$albumStr, hasLyrics=${lrcToEmbed != null}');
        await _writeTags(
          songPath,
          title: titleStr,
          artist: artistStr,
          album: albumStr,
          albumArtist: albumArtistStr,
          lyrics: lrcToEmbed,
        );
      } else {
        debugPrint('[TagWriteService] 无需写入标签');
      }
    } catch (e) {
      debugPrint('[TagWriteService] 写入音乐元信息或LRC文件失败: $e');
    } finally {
      if (coverPath != null) {
        final coverFile = File(coverPath);
        if (await coverFile.exists()) {
          await coverFile.delete().catchError((_) {});
          debugPrint('[TagWriteService] 临时封面文件已删除: $coverPath');
        }
      }
    }
  }

  Future<void> _writeTags(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
  }) async {
    try {
      final args = <String, dynamic>{
        'filePath': filePath,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (lyrics != null) 'lyrics': lyrics,
      };
      debugPrint('[TagWriteService] _writeTags args: $args');
      await _channel.invokeMethod<bool>('writeTags', args);
      debugPrint('[TagWriteService] _writeTags 成功');
    } on PlatformException catch (e) {
      debugPrint('[TagWriteService] writeTags PlatformException: ${e.code} - ${e.message}');
      rethrow;
    }
  }

  Future<void> _writeArtwork(String filePath, Uint8List artwork) async {
    try {
      debugPrint('[TagWriteService] _writeArtwork: path=$filePath, size=${artwork.length}');
      await _channel.invokeMethod<bool>('writeArtwork', {
        'filePath': filePath,
        'artwork': artwork,
      });
      debugPrint('[TagWriteService] _writeArtwork 成功');
    } on PlatformException catch (e) {
      debugPrint('[TagWriteService] writeArtwork PlatformException: ${e.code} - ${e.message}');
      rethrow;
    }
  }

  Future<void> _writeTagsAndArtwork(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    try {
      final args = <String, dynamic>{
        'filePath': filePath,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (lyrics != null) 'lyrics': lyrics,
        if (artwork != null) 'artwork': artwork,
      };
      debugPrint('[TagWriteService] _writeTagsAndArtwork args: filePath=$filePath, title=$title, artist=$artist, album=$album, albumArtist=$albumArtist, hasLyrics=${lyrics != null}, hasArtwork=${artwork != null}');
      await _channel.invokeMethod<bool>('writeTagsAndArtwork', args);
      debugPrint('[TagWriteService] _writeTagsAndArtwork 成功');
    } on PlatformException catch (e) {
      debugPrint('[TagWriteService] writeTagsAndArtwork PlatformException: ${e.code} - ${e.message}');
      rethrow;
    }
  }

  bool _isAudioFile(String filePath) {
    final ext = filePath.substring(filePath.lastIndexOf('.')).toLowerCase();
    return ['.mp3', '.flac', '.wav', '.aac', '.m4a', '.ogg', '.wma'].contains(ext);
  }

  String _baseNameWithoutExt(String filePath) {
    final lastSep = filePath.lastIndexOf(Platform.pathSeparator);
    final lastDot = filePath.lastIndexOf('.');
    if (lastDot <= lastSep) return filePath.substring(lastSep + 1);
    return filePath.substring(lastSep + 1, lastDot);
  }

  String _resolveCoverExt(String imgUrl, String? contentType) {
    final validExts = {'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
    String? urlExt;
    try {
      final uri = Uri.parse(imgUrl);
      final pathname = uri.path;
      final i = pathname.lastIndexOf('.');
      if (i != -1) {
        urlExt = pathname.substring(i).toLowerCase();
      }
    } catch (_) {}

    if (urlExt != null && validExts.contains(urlExt)) {
      return urlExt == '.jpeg' ? '.jpg' : urlExt;
    }

    if (contentType != null) {
      if (contentType.contains('image/png')) return '.png';
      if (contentType.contains('image/webp')) return '.webp';
      if (contentType.contains('image/jpeg') || contentType.contains('image/jpg')) return '.jpg';
      if (contentType.contains('image/bmp')) return '.bmp';
    }

    return '.jpg';
  }

  /// 逐字歌词格式转换：
  /// - word-by-word 模式：将 YRC/QRC/KRC 格式转换为增强 LRC 格式
  ///   （`[mm:ss.ms]<mm:ss.ms>text`），兼容其他播放器
  /// - 标准模式：清洗为标准 LRC，保证任意播放器都显示干净歌词
  String _convertLrcFormat(String lrc) {
    // 如果已经是增强 LRC 格式，直接保留
    if (isEnhancedLrcFormat(lrc)) {
      return lrc;
    }
    // 尝试解析为逐字格式并转换为增强 LRC
    final converted = _convertWordByWordToEnhancedLrc(lrc);
    if (converted.isNotEmpty) return converted;
    // 其他格式转换为标准 LRC
    return _convertToStandardLrc(lrc);
  }

  /// 将 YRC/QRC/KRC 格式转换为增强 LRC 格式
  /// YRC 格式: [lineMs,lineDur]text(wordMs,dur,0)text(wordMs,dur,0)text
  /// QRC 格式: [lineMs,lineDur](wordMs,dur,0)text(wordMs,dur,0)text
  /// KRC 格式: [lineMs,lineDur]<wordMs,dur,0>text<wordMs,dur,0>text
  /// 输出: [mm:ss.ms]<mm:ss.ms>text
  String _convertWordByWordToEnhancedLrc(String lrc) {
    if (lrc.isEmpty) return '';

    final lines = <String>[];
    // 匹配行头 [lineMs,lineDur]
    final lineRegExp = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    // 匹配 YRC/QRC 词标签 (wordMs,dur,0) 或 KRC 标签 <wordMs,dur,0>
    final wordRegExp = RegExp(r'[(<](\d+),(\d+)(?:,\d+)?[)>]');

    for (final rawLine in lrc.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final lineMatch = lineRegExp.firstMatch(line);
      if (lineMatch == null) continue;

      final lineStartMs = int.parse(lineMatch.group(1)!);
      final content = lineMatch.group(3)!;

      // 提取所有词标签的位置
      final tagMatches = wordRegExp.allMatches(content).toList();
      if (tagMatches.isEmpty) continue;

      // 构建词列表：(绝对开始时间, 词文本)
      final words = <MapEntry<int, String>>[];

      // 处理第一个标签之前的文本（QRC格式的第一个字在第一个标签之前）
      if (tagMatches.first.start > 0) {
        final firstWordText = content.substring(0, tagMatches.first.start).trim();
        if (firstWordText.isNotEmpty) {
          // 使用行开始时间作为第一个字的时间
          words.add(MapEntry(lineStartMs, firstWordText));
        }
      }

      for (int i = 0; i < tagMatches.length; i++) {
        final tagMatch = tagMatches[i];
        final absStartMs = int.parse(tagMatch.group(1)!);

        // 词文本在当前标签之后，下一个标签之前
        final textStart = tagMatch.end;
        final textEnd = i + 1 < tagMatches.length ? tagMatches[i + 1].start : content.length;
        final wordText = content.substring(textStart, textEnd).trim();

        if (wordText.isNotEmpty) {
          words.add(MapEntry(absStartMs, wordText));
        }
      }

      if (words.isEmpty) continue;

      // 构建增强 LRC 行: [mm:ss.ms]<mm:ss.ms>text
      final buffer = StringBuffer();
      buffer.write(_formatLrcTimestamp(lineStartMs));
      for (final entry in words) {
        // <mm:ss.ms>text
        final ms = entry.key;
        final mm = (ms ~/ 60000).toString().padLeft(2, '0');
        final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
        final xxx = (ms % 1000).toString().padLeft(3, '0');
        buffer.write('<$mm:$ss.$xxx>');
        buffer.write(entry.value);
      }
      lines.add(buffer.toString());
    }

    return lines.join('\n');
  }

  String _convertToStandardLrc(String lrc) {
    if (lrc.isEmpty) return '';

    final lines = parseLyricAuto(lrc);
    if (lines.isNotEmpty) {
      final buffer = StringBuffer();
      for (final line in lines) {
        final text = line.plainText.trim();
        if (text.isEmpty) continue;
        buffer.writeln('${_formatLrcTimestamp(line.startTimeMs)}$text');
      }
      final converted = buffer.toString().trim();
      if (converted.isNotEmpty) return converted;
    }

    return _cleanRawLrc(lrc);
  }

  String _formatLrcTimestamp(int ms) {
    final mm = (ms ~/ 60000).toString().padLeft(2, '0');
    final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final xxx = (ms % 1000).toString().padLeft(3, '0');
    return '[$mm:$ss.$xxx]';
  }

  /// 解析失败时的兜底清洗：保留行首时间戳，剥离所有词级标记，
  /// 避免普通播放器把标签当歌词文本显示。
  String _cleanRawLrc(String lrc) {
    final buffer = StringBuffer();
    final lineRegExp = RegExp(r'^\[(\d{1,2}):(\d{2})[.:](\d{1,3})\](.*)$');
    for (final rawLine in lrc.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final m = lineRegExp.firstMatch(line);
      if (m == null) continue;
      final head = line.substring(0, m.group(0)!.indexOf(']') + 1);
      final text = m
          .group(4)!
          .replaceAll(RegExp(r'[(（]\d+[,，]\d+(?:[,，]\d+)?[)）]'), '')
          .replaceAll(RegExp(r'<\d+(?:,\d+)+>'), '')
          .replaceAll(
            RegExp(r'[\[\［]\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?[\]\］]'),
            '',
          )
          .trim();
      if (text.isEmpty) continue;
      buffer.writeln('$head$text');
    }
    return buffer.toString().trim();
  }
}