import 'dart:convert';

import 'api_model_provider.dart';
import 'venice_wave_session.dart';

const veniceControlModel = 'z-ai-glm-5-3-flash';
const veniceControlMaxTokens = 512;

/// Control planning is independent of the conversational model selection.
/// Keep the provider's default reasoning; all commands still require local validation.
ApiModelProvider createVeniceControlProvider({
  required Uri endpoint,
  required String apiKey,
  required Map<String, dynamic> state,
}) => ApiModelProvider(
  endpoint: endpoint,
  model: veniceControlModel,
  apiKey: apiKey,
  mode: ApiReplyMode.chat,
  temperature: 0.2,
  maxTokens: veniceControlMaxTokens,
  jsonObjectOnly: true,
  systemPromptOverride:
      '${VeniceWaveSession.plannerPrompt}\nLocal state: ${jsonEncode(state)}',
);
