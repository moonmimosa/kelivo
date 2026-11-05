import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/services/nianlun/nianlun_client.dart';
import 'package:Kelivo/features/home/controllers/nianlun_binding.dart';

void main() {
  test('delivery message ids are stable per window and delivery', () {
    expect(NianlunBinding.deliveryMessageId('w1', 7), 'nianlun-w1-7');
    expect(
      NianlunBinding.deliveryMessageId('w1', 7),
      NianlunBinding.deliveryMessageId('w1', 7),
    );
    expect(
      NianlunBinding.deliveryMessageId('w1', 7),
      isNot(NianlunBinding.deliveryMessageId('w2', 7)),
    );
  });

  group('NianlunClient.normalizeBaseUrl', () {
    test('strips trailing slashes and dashboard hash', () {
      expect(
        NianlunClient.normalizeBaseUrl('https://x.test/nianlun-test/#/'),
        'https://x.test/nianlun-test',
      );
      expect(
        NianlunClient.normalizeBaseUrl('  https://x.test/nianlun/ '),
        'https://x.test/nianlun',
      );
      expect(NianlunClient.normalizeBaseUrl(''), '');
    });

    test('isConfigured needs both url and token', () {
      expect(
        NianlunClient(baseUrl: 'https://x.test/n', token: 'abc').isConfigured,
        isTrue,
      );
      expect(
        NianlunClient(baseUrl: 'https://x.test/n', token: ' ').isConfigured,
        isFalse,
      );
      expect(NianlunClient(baseUrl: '', token: 'abc').isConfigured, isFalse);
    });
  });

  group('NianlunClient.buildMessages', () {
    test(
      'keeps user/assistant text, drops streaming and empty, limits tail',
      () {
        final t0 = DateTime.utc(2026, 10, 17, 1, 2, 3);
        final msgs = <ChatMessage>[
          for (var i = 0; i < 5; i++)
            ChatMessage(
              id: 'u$i',
              role: 'user',
              content: 'hi $i',
              conversationId: 'c',
              timestamp: t0.add(Duration(minutes: i)),
            ),
          ChatMessage(
            id: 'sys',
            role: 'system',
            content: 'not synced',
            conversationId: 'c',
            timestamp: t0,
          ),
          ChatMessage(
            id: 'streaming',
            role: 'assistant',
            content: 'half',
            conversationId: 'c',
            timestamp: t0,
            isStreaming: true,
          ),
          ChatMessage(
            id: 'empty',
            role: 'assistant',
            content: '   ',
            conversationId: 'c',
            timestamp: t0,
          ),
          ChatMessage(
            id: 'wake-prompt',
            role: 'user',
            content: '${NianlunClient.internalWakePromptPrefix}内部提示',
            conversationId: 'c',
            timestamp: t0,
          ),
          ChatMessage(
            id: 'a',
            role: 'assistant',
            content: '<think>secret</think>visible',
            conversationId: 'c',
            timestamp: t0.add(const Duration(minutes: 9)),
          ),
        ];
        final out = NianlunClient.buildMessages(
          msgs,
          limit: 3,
          visibleText: (s) => s.replaceAll(RegExp(r'<think>.*?</think>'), ''),
        );
        expect(out.map((m) => m['id']), ['u3', 'u4', 'a']);
        expect(out.last['content'], 'visible');
        expect(out.first['timestamp'], '2026-10-17T01:05:03.000Z');
        expect(
          out.every((m) => m['role'] == 'user' || m['role'] == 'assistant'),
          isTrue,
        );
      },
    );

    test('internal wake prompts are excluded from synchronized history', () {
      final prompt = ChatMessage(
        id: 'wake-prompt',
        role: 'user',
        content: '  ${NianlunClient.internalWakePromptPrefix}房间内容',
        conversationId: 'c',
      );
      expect(NianlunClient.isInternalWakePrompt(prompt), isTrue);
      expect(NianlunClient.buildMessages([prompt]), isEmpty);
    });

    test(
      'internal wake asks for a context-led check without room instructions',
      () {
        expect(NianlunClient.internalWakeTriggerText, contains('最近的聊天'));
        expect(NianlunClient.internalWakeTriggerText, contains('自己判断'));
        expect(NianlunClient.internalWakeTriggerText, isNot(contains('房间内容')));
        expect(NianlunClient.internalWakeTriggerText, contains('不要回答年轮'));
      },
    );

    test('internal wake prompts are excluded from automatic memory input', () {
      ChatMessage message(String id, String role, String content) =>
          ChatMessage(
            id: id,
            role: role,
            content: content,
            conversationId: 'c',
          );

      final filtered = NianlunClient.excludeInternalWakePrompts([
        message('before', 'user', '正常聊天'),
        message('wake', 'user', '〔年轮自唤醒〕后台检查'),
        message('wake-reply', 'assistant', '这轮自然回复'),
        message('after', 'assistant', '之后的正常回复'),
      ]);

      expect(filtered.map((message) => message.id), [
        'before',
        'wake-reply',
        'after',
      ]);
    });
  });

  group('NianlunDelivery', () {
    test('parses server UTC timestamps into local time', () {
      final d = NianlunDelivery.fromJson({
        'id': 7,
        'content': '晚安。',
        'created_at': '2026-10-17 12:00:00.123456',
        'heartbeat_id': 3,
      });
      expect(d.id, 7);
      expect(d.heartbeatId, 3);
      expect(
        d.createdAt!.toUtc(),
        DateTime.utc(2026, 10, 17, 12, 0, 0, 123, 456),
      );
    });
  });

  test('buildWindowPayload marks the source as kelivo', () {
    final p = NianlunClient.buildWindowPayload(
      systemPrompt: 'persona',
      modelId: 'deepseek-chat',
      messages: const [],
      assistantName: '小狗·测试',
    );
    expect(p['source'], 'kelivo');
    expect(p['system_prompt'], 'persona');
    expect(p['assistant_name'], '小狗·测试');
  });
}
