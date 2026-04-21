import 'dart:async';
import 'package:flutter/services.dart';

class DownloadStatus {
  final String status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final bool isDownloaded;
  final String? error;

  const DownloadStatus({
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.isDownloaded,
    this.error,
  });

  factory DownloadStatus.fromMap(Map<dynamic, dynamic> map) => DownloadStatus(
    status: map['status'] as String? ?? 'notStarted',
    progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
    downloadedBytes: map['downloaded'] as int? ?? 0,
    totalBytes: map['total'] as int? ?? 0,
    isDownloaded: map['isDownloaded'] as bool? ?? false,
    error: map['error'] as String?,
  );

  factory DownloadStatus.initial() => const DownloadStatus(
    status: 'notStarted',
    progress: 0,
    downloadedBytes: 0,
    totalBytes: 0,
    isDownloaded: false,
  );

  String get displaySize {
    if (totalBytes <= 0) return '~2.6 GB';
    return _formatBytes(totalBytes);
  }

  String get downloadedDisplay => _formatBytes(downloadedBytes);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class LiteRTService {
  static const _ch = MethodChannel('com.litert/litert');
  static const _downloadCh = EventChannel('com.litert/downloadProgress');
  static const _streamCh = EventChannel('com.litert/streamResponse');

  Stream<dynamic>? _rawStreamCache;

  Stream<DownloadStatus> get downloadProgress => _downloadCh
      .receiveBroadcastStream()
      .cast<Map<dynamic, dynamic>>()
      .map(DownloadStatus.fromMap);

  Stream<dynamic> get _rawStream =>
      _rawStreamCache ??= _streamCh.receiveBroadcastStream();

  Future<bool> isModelDownloaded() async =>
      await _ch.invokeMethod<bool>('isModelDownloaded') ?? false;

  Future<String> getModelPath() async =>
      await _ch.invokeMethod<String>('getModelPath') ?? '';

  Future<DownloadStatus> getDownloadStatus() async {
    final map = await _ch.invokeMethod<Map<dynamic, dynamic>>(
      'getDownloadStatus',
    );
    return map != null ? DownloadStatus.fromMap(map) : DownloadStatus.initial();
  }

  Future<void> startDownload() => _ch.invokeMethod('startDownload');
  Future<void> pauseDownload() => _ch.invokeMethod('pauseDownload');
  Future<void> cancelDownload() => _ch.invokeMethod('cancelDownload');
  Future<void> deleteModel() => _ch.invokeMethod('deleteModel');

  Future<void> initEngine({String backend = 'gpu'}) =>
      _ch.invokeMethod('initEngine', {'backend': backend});

  Future<void> closeEngine() => _ch.invokeMethod('closeEngine');

  Future<String> getRecommendedBackend() async =>
      await _ch.invokeMethod<String>('getRecommendedBackend') ?? 'gpu';

  Future<String> getEngineStatus() async =>
      await _ch.invokeMethod<String>('getEngineStatus') ?? 'notLoaded';

  Future<void> newConversation() => _ch.invokeMethod('newConversation');

  Future<String> sendMessage(String message) async =>
      await _ch.invokeMethod<String>('sendMessage', {'message': message}) ?? '';

  Future<void> sendMessageStream(String message) =>
      _ch.invokeMethod('sendMessageStream', {'message': message});

  Future<String> sendImageMessage(Uint8List imageBytes, String text) async =>
      await _ch.invokeMethod<String>('sendImageMessage', {
        'imageBytes': imageBytes,
        'text': text,
      }) ?? '';

  Future<void> sendImageMessageStream(Uint8List imageBytes, String text) =>
      _ch.invokeMethod('sendImageMessageStream', {
        'imageBytes': imageBytes,
        'text': text,
      });

  Future<void> cancelGeneration() => _ch.invokeMethod('cancelGeneration');

  /// Streams text tokens. Closes when done, errors on failure.
  Stream<String> streamTokens() {
    return _rawStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (event, sink) {
          if (event is Map) {
            if (event['__done__'] == true) {
              sink.close();
              return;
            }
            if (event['__error__'] != null) {
              sink.addError(event['__error__'] as String);
              return;
            }
          }
          if (event is String) sink.add(event);
        },
      ),
    );
  }
}
