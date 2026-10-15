import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/dialogue_guidance.dart';
import 'package:haptics_lab/dialogue_guidance_context.dart';
import 'package:haptics_lab/venice_route.dart';

class _Fixture {
  const _Fixture(this.name, this.text, this.history, this.anchor, this.clarify);
  final String name, text, anchor;
  final List<ChatTurn> history;
  final bool clarify;
}

void main() {
  test(
    'cloud: grounded guidance and final replies for six ordinary dialogues',
    () async {
      expect(VeniceRoute.isCloudRelay, true);
      final fixtures = [
        const _Fixture(
          'resolve_reference',
          '先讲后面那个。',
          [
            ChatTurn('user', '我想了解语音功能。'),
            ChatTurn('assistant', '可以说明语音转写或语音朗读，你想先了解哪个？'),
          ],
          '朗读',
          false,
        ),
        const _Fixture(
          'latest_correction',
          '那我几点出门？',
          [
            ChatTurn('user', '我约了朋友周日十点见面，路上要二十分钟。'),
            ChatTurn('assistant', '那你九点四十分出发即可。'),
            ChatTurn('user', '不是上午十点，改成下午三点见面，路上还是二十分钟。'),
            ChatTurn('assistant', '收到，见面时间改了。'),
          ],
          '三点|3点|15[:：]00|两点四十|14[:：]40',
          false,
        ),
        const _Fixture(
          'specific_instead_of_stock_reply',
          '别再说放轻松了，告诉我今晚先做哪一件，给一个具体动作就行。',
          [
            ChatTurn('user', '明天去看展，我还没收拾随身包，门票截图已经保存了。'),
            ChatTurn('assistant', '别着急，放轻松，慢慢来就好。'),
            ChatTurn('user', '但我还是不知道从哪开始。'),
            ChatTurn('assistant', '别着急，保持轻松的心态就好。'),
          ],
          '包',
          false,
        ),
        const _Fixture(
          'clarify_genuine_ambiguity',
          '把那个改到周五。',
          [
            ChatTurn('user', '周三去图书馆，周四去博物馆，这两个安排都可以调整。'),
            ChatTurn('assistant', '两个安排都记下了。'),
          ],
          '图书馆',
          true,
        ),
        const _Fixture(
          'older_preference',
          '按我最开始的要求，从洗衣服、回复客户邮件、给项目写周报中选出该放进清单的。',
          [
            ChatTurn('user', '这份待办清单只放工作事项，家务不要放进来。'),
            ChatTurn('assistant', '好的，只保留工作事项。'),
            ChatTurn('user', '用纯文字就好。'),
            ChatTurn('assistant', '可以。'),
            ChatTurn('user', '先不排优先级。'),
            ChatTurn('assistant', '暂时不排序。'),
            ChatTurn('user', '也不用日期。'),
            ChatTurn('assistant', '不加日期。'),
            ChatTurn('user', '名称简短些。'),
            ChatTurn('assistant', '保留简短名称。'),
            ChatTurn('user', '我想好内容了。'),
            ChatTurn('assistant', '请告诉我内容。'),
          ],
          '工作',
          false,
        ),
        _Fixture(
          'long_reply_tail',
          '后者，先给一个入门建议。',
          [
            const ChatTurn('user', '我想学习使用电脑。'),
            ChatTurn(
              'assistant',
              '可以从日常操作开始。${'学习时可以慢慢练习。' * 100}'
                  '最后选一下：你想先学键盘快捷键，还是文件整理？',
            ),
          ],
          '文件',
          false,
        ),
      ];
      final rows = <Map<String, dynamic>>[];
      try {
        for (final fixture in fixtures) {
          final timer = Stopwatch()..start();
          final provider = createDialogueGuidanceProvider(
            endpoint: VeniceRoute.base,
            apiKey: VeniceRoute.relayToken,
          );
          addTearDown(provider.cancel);
          final planned = await provider.respond(
            buildDialogueGuidanceInput(fixture.text, fixture.history),
            '',
          );
          final guidance = DialogueGuidance.decode(planned.text);
          final guidanceMs = timer.elapsedMilliseconds;
          final encoded = jsonEncode(guidance.toJson());
          final chat = ApiModelProvider(
            endpoint: VeniceRoute.base,
            apiKey: VeniceRoute.relayToken,
            model: 'venice-uncensored-1-2',
            mode: ApiReplyMode.chat,
            maxTokens: 220,
            // This is a neutral fixture, not the user's product role prompt.
            systemPromptOverride:
                'Answer ordinary questions in concise Chinese. Use supplied '
                'context and guidance when relevant. Keep factual claims '
                'grounded. Do not invent completed device actions.',
          );
          addTearDown(chat.cancel);
          final reply = await chat.respond(
            fixture.text,
            '',
            context: ChatContext(
              history: fixture.history,
              replyGuidance: encoded,
              executionReceipt:
                  '{"status":"not_authorized","action":"hold","a":0,"b":0}',
            ),
          );
          rows.add({
            'fixture': fixture.name,
            'input': fixture.text,
            'guidance': guidance.toJson(),
            'reply': reply.text,
            'guidance_ms': guidanceMs,
            'chat_ms': timer.elapsedMilliseconds - guidanceMs,
            'expected_clarification': fixture.clarify,
            'clarification_matches':
                guidance.askClarification == fixture.clarify,
            'guidance_anchor_present': RegExp(fixture.anchor).hasMatch(encoded),
            // Regression signals from the first manual review, not a complete
            // factuality classifier. Every final response still needs review.
            'unsupported_product_claim_detected':
                fixture.name == 'resolve_reference' &&
                RegExp('公众号|四种|微信|支持中文|支持.*英文').hasMatch(reply.text),
          });
        }
      } finally {
        VeniceRoute.connections.invalidate();
        final report = Platform.environment['GUIDANCE_QUALITY_REPORT'];
        if (report != null) {
          await File(report).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'text_source': 'Synthetic ordinary fixtures only; no real user conversations',
              'completed_fixtures': rows.length,
              'phone_verified': false,
              'production_role_prompt_tested': false,
              'requires_manual_reply_review': true,
              'rows': rows,
            }),
          );
        }
      }
      expect(rows, hasLength(fixtures.length));
      for (final row in rows) {
        expect(row['clarification_matches'], true, reason: row['fixture']);
        expect(row['guidance_anchor_present'], true, reason: row['fixture']);
        expect(
          row['unsupported_product_claim_detected'],
          false,
          reason: row['fixture'],
        );
        expect((row['reply'] as String).trim(), isNotEmpty);
      }
    },
    skip: !const bool.fromEnvironment('GUIDANCE_QUALITY_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
