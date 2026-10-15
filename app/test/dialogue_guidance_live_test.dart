import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/chat_context.dart';
import 'package:haptics_lab/dialogue_guidance.dart';
import 'package:haptics_lab/dialogue_guidance_context.dart';
import 'package:haptics_lab/venice_route.dart';

void main() {
  test(
    'cloud: GLM guidance schema and Venice handoff with neutral fixtures',
    () async {
      expect(VeniceRoute.isCloudRelay, true);
      final rows = <Map<String, Object>>[];
      final fixtures = [
        (
          '下午吧。',
          '公园',
          const [
            ChatTurn('user', '周末想去公园散步。'),
            ChatTurn('assistant', '你想上午还是下午？'),
          ],
        ),
        (
          '先说后面那个。',
          '朗读',
          const [
            ChatTurn('user', '我想了解语音功能。'),
            ChatTurn('assistant', '可以说明转写或朗读，你先想了解哪一个？'),
          ],
        ),
      ];
      try {
        for (var i = 0; i < fixtures.length; i++) {
          final (text, anchor, history) = fixtures[i];
          final timer = Stopwatch()..start();
          final guide = createDialogueGuidanceProvider(
            endpoint: VeniceRoute.base,
            apiKey: VeniceRoute.relayToken,
          );
          addTearDown(guide.cancel);
          final planned = await guide.respond(
            buildDialogueGuidanceInput(text, history),
            '',
          );
          final validated = DialogueGuidance.decode(planned.text);
          final adviceJson = jsonEncode(validated.toJson());
          final guidanceMs = timer.elapsedMilliseconds;
          final chat = ApiModelProvider(
            endpoint: VeniceRoute.base,
            model: 'venice-uncensored-1-2',
            apiKey: VeniceRoute.relayToken,
            mode: ApiReplyMode.chat,
            maxTokens: 180,
            // A neutral transport probe, not a change to the product's role prompt.
            systemPromptOverride: 'Answer ordinary questions in concise Chinese. Use supplied context and guidance when relevant. Keep factual claims grounded. Do not invent completed device actions.',
          );
          addTearDown(chat.cancel);
          final result = await chat.respond(
            text,
            '',
            context: ChatContext(
              history: history,
              replyGuidance: adviceJson,
              executionReceipt:
                  '{"status":"not_authorized","action":"hold","a":0,"b":0}',
            ),
          );
          rows.add({
            'fixture': i + 1,
            'guidance_ms': guidanceMs,
            'chat_ms': timer.elapsedMilliseconds - guidanceMs,
            'guidance_valid': true,
            'context_keyword_present': adviceJson.contains(anchor),
            'reply_characters': result.text.length,
            'reply_nonempty': result.text.trim().isNotEmpty,
          });
          expect(result.text.trim().isNotEmpty, true);
        }
      } finally {
        VeniceRoute.connections.invalidate();
        final report = Platform.environment['GUIDANCE_LIVE_REPORT'];
        if (report != null) {
          await File(report).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'path':
                  'desktop app providers -> cloud HTTPS relay -> GLM -> Venice',
              'physical_output': false,
              'phone_verified': false,
              'production_role_prompt_tested': false,
              'semantic_quality_proven': false,
              'completed_fixtures': rows.length,
              'rows': rows,
            }),
          );
        }
      }
    },
    skip: !const bool.fromEnvironment('GUIDANCE_LIVE'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
