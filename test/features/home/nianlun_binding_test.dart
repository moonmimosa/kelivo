import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/user_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/chat_controller.dart';
import 'package:Kelivo/features/home/controllers/nianlun_binding.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';
  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// 假的年轮服务器：记录收到的请求，按脚本返回留言。
class _FakeServer {
  final requests = <http.Request>[];
  List<Map<String, Object?>> pending = [];
  final acked = <int>[];

  MockClient get client => MockClient((request) async {
    requests.add(request);
    expect(request.headers['Authorization'], 'Bearer tok');
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/deliveries')) {
      return http.Response(
        jsonEncode({'window_id': 'w1', 'deliveries': pending}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.method == 'POST' && path.endsWith('/deliveries/ack')) {
      final ids = (jsonDecode(request.body)['ids'] as List).cast<int>();
      acked.addAll(ids);
      return http.Response(jsonEncode({'acked': ids.length}), 200);
    }
    if (request.method == 'PUT' && path.startsWith('/nl/api/client/windows/')) {
      return http.Response(jsonEncode({'status': 'saved'}), 200);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  const enabled = Assistant(
    id: 'a',
    name: '小狗·测试',
    systemPrompt: '我是{assistant_name}。',
    chatModelProvider: 'p',
    chatModelId: 'deepseek-flash',
    nianlunEnabled: true,
    nianlunBaseUrl: 'https://n.test/nl/',
    nianlunToken: 'tok',
    nianlunWindowId: 'w1',
  );
  const other = Assistant(id: 'b', name: 'Other');

  late Directory tempDir;
  late BusinessTestHarness storage;
  late AssistantProvider assistants;
  late UserProvider user;
  late ChatService chat;
  late ChatController controller;
  late _FakeServer server;
  late NianlunBinding binding;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_nianlun_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    storage = await createBusinessTestHarness(
      initial: {
        'assistants_v1': jsonEncode([enabled.toJson(), other.toJson()]),
      },
    );
    chat = ChatService(
      existingRepository: ChatDatabaseRepository(storage.database),
    );
    assistants = AssistantProvider(preferences: storage.preferences);
    user = UserProvider(preferences: storage.preferences);
    controller = ChatController(chatService: chat);
    server = _FakeServer();
  });

  tearDown(() async {
    binding.dispose();
    controller.dispose();
    assistants.dispose();
    user.dispose();
    await chat.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> mount(WidgetTester tester) async {
    late BuildContext context;
    await tester.runAsync(() async {
      await chat.init();
      await assistants.loaded;
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<UserProvider>.value(value: user),
          ChangeNotifierProvider<ChatService>.value(value: chat),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    binding = NianlunBinding(
      context: context,
      chat: chat,
      chatController: controller,
      httpClient: server.client,
    );
  }

  testWidgets('poll inserts his message into the assistant conversation '
      'once and acknowledges it', (tester) async {
    await mount(tester);
    await tester.runAsync(() async {
      final convo = await chat.createConversation(title: 't', assistantId: 'a');
      final otherConvo = await chat.createConversation(
        title: 'o',
        assistantId: 'b',
      );
      server.pending = [
        {
          'id': 7,
          'content': '改了一行诗。睡吧。',
          'created_at': '2026-10-17 12:00:00.000000',
          'heartbeat_id': 3,
        },
      ];

      await binding.poll(force: true);

      final messages = await chat.loadMessages(convo.id);
      final his = messages.where(
        (m) => m.id == NianlunBinding.deliveryMessageId('w1', 7),
      );
      expect(his, hasLength(1));
      expect(his.single.role, 'assistant');
      expect(his.single.content, '改了一行诗。睡吧。');
      expect(his.single.timestamp.toUtc(), DateTime.utc(2026, 10, 17, 12));
      expect(server.acked, [7]);
      expect(await chat.loadMessages(otherConvo.id), isEmpty);

      // 回执丢了：服务器再递一次同一条 → 不会插第二遍，但会再回执。
      await binding.poll(force: true);
      final again = await chat.loadMessages(convo.id);
      expect(
        again.where((m) => m.id == NianlunBinding.deliveryMessageId('w1', 7)),
        hasLength(1),
      );
      expect(server.acked, [7, 7]);
    });
  });

  testWidgets('poll creates a conversation when the assistant has none', (
    tester,
  ) async {
    await mount(tester);
    await tester.runAsync(() async {
      server.pending = [
        {'id': 1, 'content': '早。', 'created_at': null},
        {'id': 2, 'content': '   ', 'created_at': null},
      ];
      await binding.poll(force: true);
      final convos = chat
          .getAllConversations()
          .where((c) => c.assistantId == 'a')
          .toList();
      expect(convos, hasLength(1));
      final messages = await chat.loadMessages(convos.single.id);
      expect(messages.map((m) => m.content), ['早。']);
      expect(server.acked, [1, 2]); // 空白留言直接回执掉
    });
  });

  testWidgets('finished reply syncs persona and recent messages', (
    tester,
  ) async {
    await mount(tester);
    await tester.runAsync(() async {
      final convo = await chat.createConversation(title: 't', assistantId: 'a');
      await chat.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: '今天好累',
      );
      final reply = await chat.addMessage(
        conversationId: convo.id,
        role: 'assistant',
        content: '<think>想想</think>先吃点东西。',
        modelId: 'deepseek-flash',
      );

      await binding.onAssistantMessageFinished(reply);

      final put = server.requests.singleWhere((r) => r.method == 'PUT');
      expect(put.url.toString(), 'https://n.test/nl/api/client/windows/w1');
      final body = jsonDecode(put.body) as Map<String, dynamic>;
      expect(body['system_prompt'], '我是小狗·测试。');
      expect(body['model_id'], 'deepseek-flash');
      expect(body['assistant_name'], '小狗·测试');
      expect(body['source'], 'kelivo');
      final sent = (body['messages'] as List).cast<Map<String, dynamic>>();
      expect(sent.map((m) => m['role']), ['user', 'assistant']);
      expect(sent.map((m) => m['content']), ['今天好累', '先吃点东西。']);
    });
  });

  testWidgets('disabled assistants never touch the network', (tester) async {
    await mount(tester);
    await tester.runAsync(() async {
      await assistants.updateAssistant(enabled.copyWith(nianlunEnabled: false));
      final convo = await chat.createConversation(title: 't', assistantId: 'a');
      final reply = await chat.addMessage(
        conversationId: convo.id,
        role: 'assistant',
        content: 'hi',
      );
      await binding.onAssistantMessageFinished(reply);
      await binding.poll(force: true);
      expect(server.requests, isEmpty);
    });
  });
}
