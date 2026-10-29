import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/chat_message.dart';

/// 年轮（nianlun）服务器的薄客户端。
///
/// 三件事：把这个助手「此刻的窗口」同步过去（人格 + 最近对话），取他醒来留的话，
/// 回执已经放进聊天窗口的那些。全部失败都只记日志，不影响聊天。
class NianlunClient {
  NianlunClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _client = httpClient;

  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client? _client;

  static const int syncMessageLimit = 30;

  bool get isConfigured =>
      normalizeBaseUrl(baseUrl).isNotEmpty && token.trim().isNotEmpty;

  /// 去掉结尾的斜杠；允许用户把仪表盘地址直接粘进来（带 #/ 的也行）。
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${token.trim()}',
  };

  Uri _uri(String path) => Uri.parse('${normalizeBaseUrl(baseUrl)}$path');

  /// 把聊天记录整理成服务器要的样子：只留 user/assistant、可见正文、ISO 时间。
  static List<Map<String, dynamic>> buildMessages(
    List<ChatMessage> messages, {
    int limit = syncMessageLimit,
    String Function(String)? visibleText,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role != 'user' && m.role != 'assistant') continue;
      if (m.isStreaming) continue;
      final raw = m.content;
      final text = (visibleText?.call(raw) ?? raw).trim();
      if (text.isEmpty) continue;
      out.add({
        'id': m.id,
        'role': m.role,
        'content': text,
        'timestamp': m.timestamp.toUtc().toIso8601String(),
      });
    }
    if (out.length > limit) return out.sublist(out.length - limit);
    return out;
  }

  static Map<String, dynamic> buildWindowPayload({
    required String systemPrompt,
    required String? modelId,
    required List<Map<String, dynamic>> messages,
    String? assistantName,
  }) => {
    'system_prompt': systemPrompt,
    'model_id': modelId,
    'messages': messages,
    'assistant_name': assistantName,
    'source': 'kelivo',
  };

  Future<T> _withClient<T>(Future<T> Function(http.Client client) run) async {
    final owned = _client == null;
    final client = _client ?? http.Client();
    try {
      return await run(client);
    } finally {
      if (owned) client.close();
    }
  }

  Future<bool> healthz() => _withClient((client) async {
    final r = await client.get(_uri('/healthz')).timeout(timeout);
    return r.statusCode == 200;
  });

  /// 替换式同步：服务器只保留最后一次送去的副本。
  Future<void> syncWindow(String windowId, Map<String, dynamic> payload) =>
      _withClient((client) async {
        final r = await client
            .put(
              _uri('/api/client/windows/${Uri.encodeComponent(windowId)}'),
              headers: _headers,
              body: jsonEncode(payload),
            )
            .timeout(timeout);
        if (r.statusCode != 200) {
          throw NianlunHttpException(r.statusCode, r.body);
        }
      });

  Future<List<NianlunDelivery>> fetchDeliveries(String windowId) => _withClient(
    (client) async {
      final r = await client
          .get(
            _uri(
              '/api/client/windows/${Uri.encodeComponent(windowId)}/deliveries',
            ),
            headers: _headers,
          )
          .timeout(timeout);
      if (r.statusCode != 200) {
        throw NianlunHttpException(r.statusCode, r.body);
      }
      final data = jsonDecode(r.body);
      final list = (data is Map ? data['deliveries'] : null) as List? ?? [];
      return list
          .whereType<Map>()
          .map((e) => NianlunDelivery.fromJson(e.cast<String, dynamic>()))
          .toList();
    },
  );

  Future<int> ack(String windowId, List<int> ids) => _withClient((
    client,
  ) async {
    if (ids.isEmpty) return 0;
    final r = await client
        .post(
          _uri(
            '/api/client/windows/${Uri.encodeComponent(windowId)}/deliveries/ack',
          ),
          headers: _headers,
          body: jsonEncode({'ids': ids}),
        )
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw NianlunHttpException(r.statusCode, r.body);
    }
    final data = jsonDecode(r.body);
    return (data is Map ? data['acked'] as int? : null) ?? 0;
  });

  Future<List<NianlunWakeRequest>> fetchWakeRequests(
    String windowId,
  ) => _withClient((client) async {
    final r = await client
        .get(
          _uri(
            '/api/client/windows/${Uri.encodeComponent(windowId)}/wake-requests',
          ),
          headers: _headers,
        )
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw NianlunHttpException(r.statusCode, r.body);
    }
    final data = jsonDecode(r.body);
    final list = (data is Map ? data['requests'] : null) as List? ?? [];
    return list
        .whereType<Map>()
        .map((e) => NianlunWakeRequest.fromJson(e.cast<String, dynamic>()))
        .toList();
  });

  Future<void> completeWakeRequest(
    String windowId,
    int requestId, {
    required bool ok,
    required String outcome,
    required int contentChars,
    String? error,
  }) => _withClient((client) async {
    final r = await client
        .post(
          _uri(
            '/api/client/windows/${Uri.encodeComponent(windowId)}/wake-requests/$requestId/complete',
          ),
          headers: _headers,
          body: jsonEncode({
            'ok': ok,
            'outcome': outcome,
            'content_chars': contentChars,
            if (error != null) 'error': error,
          }),
        )
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw NianlunHttpException(r.statusCode, r.body);
    }
  });
}

class NianlunDelivery {
  const NianlunDelivery({
    required this.id,
    required this.content,
    required this.createdAt,
    this.heartbeatId,
  });

  final int id;
  final String content;
  final DateTime? createdAt;
  final int? heartbeatId;

  static NianlunDelivery fromJson(Map<String, dynamic> json) => NianlunDelivery(
    id: (json['id'] as num).toInt(),
    content: (json['content'] as String?) ?? '',
    createdAt: parseServerTime(json['created_at'] as String?),
    heartbeatId: (json['heartbeat_id'] as num?)?.toInt(),
  );

  /// 服务器时间是 UTC 的 `YYYY-MM-DD HH:MM:SS.ffffff`。
  static DateTime? parseServerTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim().replaceFirst(' ', 'T');
    final dt = DateTime.tryParse(s.endsWith('Z') ? s : '${s}Z');
    return dt?.toLocal();
  }
}

class NianlunWakeRequest {
  const NianlunWakeRequest({
    required this.id,
    required this.heartbeatId,
    required this.mode,
    required this.prompt,
    required this.createdAt,
  });

  final int id;
  final int heartbeatId;
  final String mode;
  final String prompt;
  final DateTime? createdAt;

  static NianlunWakeRequest fromJson(Map<String, dynamic> json) =>
      NianlunWakeRequest(
        id: (json['id'] as num).toInt(),
        heartbeatId: (json['heartbeat_id'] as num).toInt(),
        mode: (json['mode'] as String?) ?? 'room',
        prompt: (json['prompt'] as String?) ?? '',
        createdAt: NianlunDelivery.parseServerTime(
          json['created_at'] as String?,
        ),
      );
}

class NianlunHttpException implements Exception {
  const NianlunHttpException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() =>
      'NianlunHttpException($statusCode): ${body.length > 200 ? body.substring(0, 200) : body}';
}
