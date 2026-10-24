import 'package:hoshi/domain/models.dart';

DateTime? sourceTime(Object? value) {
  final time = DateTime.tryParse('$value');
  return time != null && time.year >= 2000 ? time.toLocal() : null;
}

class SourceHealthStep {
  SourceHealthStep.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String? ?? '',
      state = json['state'] as String? ?? '',
      message = json['message'] as String? ?? '',
      host = json['host'] as String? ?? '',
      httpStatus = intValue(json['httpStatus']),
      elapsedMs = intValue(json['elapsedMs']),
      cfRay = json['cfRay'] as String? ?? '';

  SourceHealthStep({
    required this.name,
    required this.state,
    required this.message,
    this.host = '',
    this.httpStatus = 0,
    required this.elapsedMs,
    this.cfRay = '',
  });

  final String name, state, message, host, cfRay;
  final int httpStatus, elapsedMs;
}

class SourceHealth {
  SourceHealth.fromJson(Map<String, dynamic> json)
    : checkedAt = sourceTime(json['checkedAt']),
      state = json['state'] as String? ?? '',
      sample = json['sample'] as String? ?? '',
      steps = [
        for (final step in json['steps'] as List? ?? [])
          SourceHealthStep.fromJson(Map<String, dynamic>.from(step as Map)),
      ];

  SourceHealth({
    required this.checkedAt,
    required this.state,
    required this.sample,
    required this.steps,
  });

  final DateTime? checkedAt;
  final String state, sample;
  final List<SourceHealthStep> steps;
  String get label => switch (state) {
    'ok' => '连接检测通过',
    'catalogOnly' => '目录正常 · 播放未检测',
    'checking' => '检测中',
    'failed' => '检测未通过',
    _ => '尚未检测',
  };
}

class SourceStatus {
  SourceStatus.fromJson(Map<String, dynamic> json)
    : source = json['source'] as String? ?? '',
      count = intValue(json['count']),
      unknownVip = intValue(json['unknownVip']),
      page = intValue(json['page']),
      hasMore = json['hasMore'] == true,
      updatedAt = sourceTime(json['updatedAt']),
      running = json['running'] == true,
      operation = json['operation'] as String? ?? '',
      stage = json['stage'] as String? ?? '',
      completed = intValue(json['completed']),
      total = intValue(json['total']),
      added = intValue(json['added']),
      error = json['error'] as String? ?? '',
      storageError = json['storageError'] as String? ?? '',
      startedAt = sourceTime(json['startedAt']),
      finishedAt = sourceTime(json['finishedAt']),
      retryAt = sourceTime(json['retryAt']),
      health = json['health'] is Map
          ? SourceHealth.fromJson(
              Map<String, dynamic>.from(json['health'] as Map),
            )
          : null;

  SourceStatus({
    required this.source,
    this.count = 0,
    this.unknownVip = 0,
    this.page = 0,
    this.hasMore = false,
    this.updatedAt,
    this.running = false,
    this.operation = '',
    this.stage = '',
    this.completed = 0,
    this.total = 0,
    this.added = 0,
    this.error = '',
    this.storageError = '',
    this.startedAt,
    this.finishedAt,
    this.retryAt,
    this.health,
  });

  final String source, operation, stage, error, storageError;
  final int count, page, completed, total, added, unknownVip;
  final bool hasMore, running;
  final DateTime? updatedAt, startedAt, finishedAt, retryAt;
  final SourceHealth? health;

  int get retrySeconds {
    if (retryAt == null) return 0;
    return ((retryAt!.difference(DateTime.now()).inMilliseconds / 1000).ceil())
        .clamp(0, 3600);
  }
}
