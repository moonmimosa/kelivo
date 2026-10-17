import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_prompt_settings.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/nianlun/nianlun_client.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';

/// 把年轮接进聊天页：
/// - 每次助手回复完成 → 把这个助手「此刻的窗口」（人格 + 最近对话）同步给年轮；
/// - 回到前台 / 切换对话 / 每分钟 → 去年轮取他醒来留的话，插进该助手的当前对话，再回执。
/// 任何失败只打日志，绝不影响聊天本身。
class NianlunBinding {
  NianlunBinding({
    required this.context,
    required this.chat,
    required this.chatController,
  });

  static const Duration pollInterval = Duration(minutes: 1);
  static const Duration minPollGap = Duration(seconds: 20);
  static const String _deliveredPrefsKey = 'nianlun_delivered_v1';
  static const int _deliveredKeep = 500;

  final BuildContext context;
  final ChatService chat;
  final ChatController chatController;

  Timer? _timer;
  bool _disposed = false;
  bool _polling = false;
  bool _syncing = false;
  DateTime? _lastPollAt;
  List<String> _delivered = const [];
  bool _deliveredLoaded = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
    unawaited(poll());
  }

  void onAppResumed() => unawaited(poll(force: true));

  void onConversationSwitched() => unawaited(poll());

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  // ---------------------------------------------------------------------------
  // 同步窗口
  // ---------------------------------------------------------------------------

  Future<void> onAssistantMessageFinished(ChatMessage message) async {
    if (_disposed || _syncing || !context.mounted) return;
    if (message.role != 'assistant') return;
    final conversation = chat.getConversation(message.conversationId);
    if (conversation == null) return;
    final assistant = _assistantFor(conversation);
    if (assistant == null || !assistant.nianlunEnabled) return;
    final client = NianlunClient(
      baseUrl: assistant.nianlunBaseUrl,
      token: assistant.nianlunToken,
    );
    if (!client.isConfigured) return;
    // 需要 BuildContext 的都在第一个 await 之前算好。
    final modelId = message.modelId ?? assistant.chatModelId;
    final systemPrompt = _renderSystemPrompt(assistant, conversation, modelId);
    final windowId = _windowIdFor(assistant);

    _syncing = true;
    try {
      final history = await chat.loadSelectedContextMessages(
        conversation.id,
        truncateIndex: conversation.truncateIndex,
        limit: NianlunClient.syncMessageLimit,
      );
      final payload = NianlunClient.buildWindowPayload(
        systemPrompt: systemPrompt,
        modelId: modelId,
        assistantName: assistant.name,
        messages: NianlunClient.buildMessages(
          history,
          visibleText: (text) =>
              ThinkingTagParser.parseWithRanges(text).visibleContent,
        ),
      );
      await client.syncWindow(windowId, payload);
    } catch (e) {
      debugPrint('[nianlun] sync failed: $e');
    } finally {
      _syncing = false;
    }
  }

  String _renderSystemPrompt(
    Assistant assistant,
    Conversation conversation,
    String? modelId,
  ) {
    final prompt = ConversationPromptSettings.fromExtras(
      conversation.extras,
    ).effectiveSystemPrompt(assistant);
    if (prompt.trim().isEmpty) return '';
    final vars = PromptTransformer.buildPlaceholders(
      context: context,
      assistant: assistant,
      modelId: modelId,
      modelName: modelId,
      userNickname: context.read<UserProvider>().name,
    );
    return PromptTransformer.replacePlaceholders(prompt, vars);
  }

  Assistant? _assistantFor(Conversation conversation) {
    final provider = context.read<AssistantProvider>();
    final id = conversation.assistantId;
    return id != null ? provider.getById(id) : provider.currentAssistant;
  }

  /// 窗口编号在设置页打开开关时就生成了；这里只兜底补一个（不等待保存完成）。
  String _windowIdFor(Assistant assistant) {
    if (assistant.nianlunWindowId.isNotEmpty) return assistant.nianlunWindowId;
    final id = const Uuid().v4();
    unawaited(
      context
          .read<AssistantProvider>()
          .updateAssistant(assistant.copyWith(nianlunWindowId: id))
          .catchError((Object e) {
            debugPrint('[nianlun] window id save failed: $e');
          }),
    );
    return id;
  }

  // ---------------------------------------------------------------------------
  // 取他留的话
  // ---------------------------------------------------------------------------

  Future<void> poll({bool force = false}) async {
    if (_disposed || _polling || !context.mounted) return;
    final now = DateTime.now();
    if (!force &&
        _lastPollAt != null &&
        now.difference(_lastPollAt!) < minPollGap) {
      return;
    }
    // 正在生成回复时不往对话里插东西，下一轮再来。
    if (ChatActions.hasAnyActiveGeneration) return;
    // BuildContext 只在这里（await 之前）用。
    final assistants = context
        .read<AssistantProvider>()
        .assistants
        .where((a) => a.nianlunEnabled && a.nianlunWindowId.isNotEmpty)
        .toList();
    if (assistants.isEmpty) return;
    _polling = true;
    _lastPollAt = now;
    try {
      await _loadDelivered();
      for (final assistant in assistants) {
        if (_disposed) return;
        await _pollAssistant(assistant);
      }
    } catch (e) {
      debugPrint('[nianlun] poll failed: $e');
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollAssistant(Assistant assistant) async {
    final client = NianlunClient(
      baseUrl: assistant.nianlunBaseUrl,
      token: assistant.nianlunToken,
    );
    if (!client.isConfigured) return;
    final windowId = assistant.nianlunWindowId;
    final List<NianlunDelivery> deliveries;
    try {
      deliveries = await client.fetchDeliveries(windowId);
    } catch (e) {
      debugPrint('[nianlun] fetch failed: $e');
      return;
    }
    if (deliveries.isEmpty) return;

    final ackIds = <int>[];
    Conversation? target;
    for (final d in deliveries) {
      final key = '$windowId:${d.id}';
      if (_delivered.contains(key) || d.content.trim().isEmpty) {
        ackIds.add(d.id);
        continue;
      }
      target ??= await _targetConversation(assistant);
      if (target == null) break;
      try {
        await chat.addMessage(
          conversationId: target.id,
          role: 'assistant',
          content: d.content,
          modelId: assistant.chatModelId,
          providerId: assistant.chatModelProvider,
        );
      } catch (e) {
        debugPrint('[nianlun] insert failed: $e');
        break;
      }
      await _rememberDelivered(key);
      ackIds.add(d.id);
    }

    if (target != null && chatController.currentConversation?.id == target.id) {
      chatController.updateCurrentConversation(chat.getConversation(target.id));
      await chatController.refreshTimelineAfterMutation();
    }
    if (ackIds.isNotEmpty) {
      try {
        await client.ack(windowId, ackIds);
      } catch (e) {
        debugPrint('[nianlun] ack failed: $e');
      }
    }
  }

  /// 他的话放进哪里：正在看的那个对话（如果属于这个助手），否则这个助手最近的对话，都没有就新开一个。
  Future<Conversation?> _targetConversation(Assistant assistant) async {
    final current = chatController.currentConversation;
    if (current != null &&
        current.assistantId == assistant.id &&
        !chat.isTemporaryConversation(current.id)) {
      return current;
    }
    for (final c in chat.getAllConversations()) {
      if (c.assistantId == assistant.id &&
          !chat.isTemporaryConversation(c.id)) {
        return c;
      }
    }
    try {
      return await chat.createConversation(
        title: assistant.name,
        assistantId: assistant.id,
        activate: false,
      );
    } catch (e) {
      debugPrint('[nianlun] create conversation failed: $e');
      return null;
    }
  }

  Future<void> _loadDelivered() async {
    if (_deliveredLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_deliveredPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) _delivered = list.whereType<String>().toList();
      }
    } catch (_) {
      _delivered = const [];
    }
    _deliveredLoaded = true;
  }

  Future<void> _rememberDelivered(String key) async {
    final next = [..._delivered, key];
    _delivered = next.length > _deliveredKeep
        ? next.sublist(next.length - _deliveredKeep)
        : next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deliveredPrefsKey, jsonEncode(_delivered));
    } catch (_) {}
  }
}
