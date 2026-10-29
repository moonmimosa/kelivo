import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_prompt_settings.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/nianlun/nianlun_client.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';
import 'home_view_model.dart';

/// 把年轮接进聊天页：
/// - 每次助手回复完成 → 把这个助手「此刻的窗口」（人格 + 最近对话）同步给年轮；
/// - 回到前台 / 切换对话 / 每分钟 → 去年轮取他醒来留的话，插进该助手的当前对话，再回执。
/// 插入用确定的消息 id（年轮窗口 + 留言编号），同一条不会被插两次。
/// 任何失败只打日志，绝不影响聊天本身。
class NianlunBinding {
  NianlunBinding({
    required this.context,
    required this.chat,
    required this.chatController,
    this.viewModel,
    this.httpClient,
  });

  static const Duration pollInterval = Duration(minutes: 1);
  static const Duration minPollGap = Duration(seconds: 20);

  final BuildContext context;
  final ChatService chat;
  final ChatController chatController;
  final HomeViewModel? viewModel;

  /// 测试时注入；正常运行为 null（每次请求自己开关连接）。
  final http.Client? httpClient;

  Timer? _timer;
  bool _disposed = false;
  bool _polling = false;
  bool _syncing = false;
  DateTime? _lastPollAt;
  final Map<String, _PendingWake> _pendingWakes = <String, _PendingWake>{};

  /// 他留的话在本地的消息 id：同一个窗口、同一条留言永远是同一个 id。
  static String deliveryMessageId(String windowId, int deliveryId) =>
      'nianlun-$windowId-$deliveryId';

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
      httpClient: httpClient,
    );
    if (!client.isConfigured) return;
    final pendingWake = _pendingWakes.remove(message.id);
    // 需要 BuildContext 的都在第一个 await 之前算好。
    final modelId = message.modelId ?? assistant.chatModelId;
    final systemPrompt = _renderSystemPrompt(assistant, conversation, modelId);
    final windowId = pendingWake?.windowId ?? _windowIdFor(assistant);

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
      if (pendingWake != null) {
        await client.completeWakeRequest(
          windowId,
          pendingWake.request.id,
          ok: message.content.trim().isNotEmpty,
          outcome: message.content.trim().isNotEmpty ? 'replied' : 'silent',
          contentChars: message.content.trim().length,
        );
      }
    } catch (e) {
      debugPrint('[nianlun] sync failed: $e');
      if (pendingWake != null) {
        try {
          await client.completeWakeRequest(
            windowId,
            pendingWake.request.id,
            ok: false,
            outcome: 'failed',
            contentChars: 0,
            error: e.toString(),
          );
        } catch (completeError) {
          debugPrint('[nianlun] wake completion failed: $completeError');
        }
      }
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
      httpClient: httpClient,
    );
    if (!client.isConfigured) return;
    final windowId = assistant.nianlunWindowId;
    await _pollWakeRequests(assistant, client, windowId);
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
      if (d.content.trim().isEmpty) {
        ackIds.add(d.id);
        continue;
      }
      target ??= await _targetConversation(assistant);
      if (target == null) break;
      try {
        // 同一个 id 已经在这个对话里时，ChatService 会直接跳过——天然防重复。
        await chat.addMessageDirectly(
          target.id,
          ChatMessage(
            id: deliveryMessageId(windowId, d.id),
            role: 'assistant',
            content: d.content,
            conversationId: target.id,
            timestamp: d.createdAt ?? DateTime.now(),
            modelId: assistant.chatModelId,
            providerId: assistant.chatModelProvider,
          ),
        );
      } catch (e) {
        debugPrint('[nianlun] insert failed: $e');
        break;
      }
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

  Future<void> _pollWakeRequests(
    Assistant assistant,
    NianlunClient client,
    String windowId,
  ) async {
    final runtime = viewModel;
    if (runtime == null) return;
    final List<NianlunWakeRequest> requests;
    try {
      requests = await client.fetchWakeRequests(windowId);
    } catch (e) {
      debugPrint('[nianlun] wake request fetch failed: $e');
      return;
    }
    for (final request in requests) {
      if (_disposed) return;
      final target = await _targetConversation(assistant);
      if (target == null) return;
      final result = await runtime.sendScheduledMessage(
        input: ChatInputData(
          text:
              '〔年轮自唤醒〕这是你自己醒来的一轮。请按你平时的方式使用记忆、工具和人格处理下面的房间内容；如果不想打扰她，可以保持沉默。\n\n${request.prompt}',
        ),
        conversation: target,
        assistant: assistant,
        scheduledNotify: false,
        scheduledPreview: false,
      );
      if (result.success && result.assistantMessage != null) {
        _pendingWakes[result.assistantMessage!.id] = _PendingWake(
          request: request,
          windowId: windowId,
        );
      } else if (result.errorMessage != 'in_flight') {
        try {
          await client.completeWakeRequest(
            windowId,
            request.id,
            ok: false,
            outcome: 'failed',
            contentChars: 0,
            error: result.errorMessage ?? 'Kelivo 未启动生成',
          );
        } catch (e) {
          debugPrint('[nianlun] wake rejection completion failed: $e');
        }
      }
    }
  }

  /// 他的话放进哪里：正在看的那个对话（如果属于这个助手且已经保存），
  /// 否则这个助手最近的对话，都没有就新开一个。
  Future<Conversation?> _targetConversation(Assistant assistant) async {
    final saved = chat
        .getAllConversations()
        .where(
          (c) =>
              c.assistantId == assistant.id &&
              !chat.isTemporaryConversation(c.id),
        )
        .toList();
    final currentId = chatController.currentConversation?.id;
    for (final c in saved) {
      if (c.id == currentId) return c;
    }
    if (saved.isNotEmpty) return saved.first;
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
}

class _PendingWake {
  const _PendingWake({required this.request, required this.windowId});

  final NianlunWakeRequest request;
  final String windowId;
}
