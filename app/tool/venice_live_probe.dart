// Explicit live check: key and synthetic WAV arrive via stdin, never arguments.
// Reuses the production providers. Only safe result metadata is printed.
import 'dart:convert';
import 'dart:io';

import 'package:haptics_lab/api_model_provider.dart';
import 'package:haptics_lab/venice_transcription.dart';

Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final key = input['key'] as String;
  final result = <String, Object?>{};
  try {
    final reply = await ApiModelProvider(
      endpoint: Uri.parse('https://api.venice.ai/api/v1'),
      model: veniceTextModel,
      apiKey: key,
      mode: ApiReplyMode.chat,
      maxTokens: 40,
    ).respond('请只回复：连接成功。', '');
    result['chat_ok'] = reply.text.isNotEmpty;
    result['chat_characters'] = reply.text.length;
  } on ModelServiceException catch (error) {
    result['chat_ok'] = false;
    result['chat_error'] = error.message;
  } catch (_) {
    result['chat_ok'] = false;
    result['chat_error'] = 'Unexpected local error';
  }
  try {
    final transcript = await VeniceTranscriber(apiKey: key)
        .transcribe(pcmToWav(base64Decode(input['pcm'] as String)));
    result['stt_ok'] = transcript.isNotEmpty;
    result['stt_characters'] = transcript.length;
    result['synthetic_fixture_recognized'] = transcript.toLowerCase().contains(
      'hello',
    );
  } on ModelServiceException catch (error) {
    result['stt_ok'] = false;
    result['stt_error'] = error.message;
  } catch (_) {
    result['stt_ok'] = false;
    result['stt_error'] = 'Unexpected local error';
  }
  stdout.writeln(jsonEncode(result));
}
