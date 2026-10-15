import 'control_slider.dart';
import 'localization.dart';

import 'package:flutter/material.dart';

import 'api_model_provider.dart';
import 'model_provider.dart';
import 'preferences_store.dart';

enum ModelSource { demo, local, api }

class ModelConfiguration {
  ModelSource source = ModelSource.demo;
  ApiReplyMode replyMode = ApiReplyMode.tools;
  double temperature = 0.8;
  int timeoutSeconds = 30;
  int maxTokens = 1200;
  String style = '温柔';
  final localEndpoint = TextEditingController(
    text: 'http://127.0.0.1:1234/v1/chat/completions',
  );
  final apiEndpoint = TextEditingController();
  final model = TextEditingController();
  final apiKey = TextEditingController();
  final persona = TextEditingController(text: '自然、俏皮，认真回应我的话；少用客服语气，不重复固定开场。');
  String get label => switch (source) {
    ModelSource.demo => '演示助手 · 固定规则，未接入大模型',
    ModelSource.local => '本机模型 · 发送最近对话和仿真状态',
    ModelSource.api => 'API 模型 · 发送最近对话和仿真状态到你填写的服务',
  };
  ModelProvider createProvider() => switch (source) {
    ModelSource.demo => const FakeModelProvider(),
    ModelSource.local => createLocalProvider(),
    ModelSource.api => ApiModelProvider(
      endpoint: Uri.parse(apiEndpoint.text.trim()),
      model: model.text.trim(),
      apiKey: apiKey.text.trim(),
      mode: replyMode,
      temperature: temperature,
      timeout: Duration(seconds: timeoutSeconds),
      maxTokens: maxTokens,
    ),
  };
  ModelProvider createLocalProvider() {
    final endpoint = Uri.parse(localEndpoint.text.trim());
    if (endpoint.scheme != 'http' ||
        !['127.0.0.1', 'localhost', '::1'].contains(endpoint.host)) {
      throw ArgumentError('本机模型仅允许本机 HTTP 地址');
    }
    return ApiModelProvider(
      endpoint: endpoint,
      model: model.text.trim(),
      mode: ApiReplyMode.json,
      temperature: temperature,
      timeout: Duration(seconds: timeoutSeconds),
      maxTokens: maxTokens,
    );
  }

  Map<String, dynamic> savedPreferences() => PreferencesStore.validate({
    'version': 1,
    'source': source.name,
    'replyMode': replyMode.name,
    'temperature': temperature,
    'timeoutSeconds': timeoutSeconds,
    'maxTokens': maxTokens,
    'style': style,
    'localEndpoint': localEndpoint.text.trim(),
    'apiEndpoint': apiEndpoint.text.trim(),
    'model': model.text.trim(),
    'persona': persona.text,
  });

  void restorePreferences(Map<String, dynamic> value) {
    final saved = PreferencesStore.validate(value);
    source = ModelSource.values.byName(saved['source']);
    replyMode = ApiReplyMode.values.byName(saved['replyMode']);
    temperature = (saved['temperature'] as num).toDouble();
    timeoutSeconds = saved['timeoutSeconds'];
    maxTokens = saved['maxTokens'];
    style = saved['style'];
    localEndpoint.text = saved['localEndpoint'];
    apiEndpoint.text = saved['apiEndpoint'];
    model.text = saved['model'];
    persona.text = saved['persona'];
  }

  void dispose() {
    apiKey.clear();
    for (final controller in [
      localEndpoint,
      apiEndpoint,
      model,
      apiKey,
      persona,
    ]) {
      controller.dispose();
    }
  }
}

class ModelSettings extends StatelessWidget {
  const ModelSettings({
    super.key,
    required this.configuration,
    required this.busy,
    required this.onChanged,
    required this.onTest,
    required this.testStatus,
    this.onSave,
    this.onForget,
    this.storageStatus = '',
  });
  final ModelConfiguration configuration;
  final bool busy;
  final VoidCallback onChanged, onTest;
  final String testStatus;
  final VoidCallback? onSave, onForget;
  final String storageStatus;
  @override
  Widget build(BuildContext context) {
    final c = configuration;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const LText('模型与对话设置', style: TextStyle(fontSize: 13)),
      children: [
        DropdownButtonFormField<ModelSource>(
          isExpanded: true,
          key: const Key('model_source'),
          initialValue: c.source,
          decoration: const InputDecoration(label: LText('回复来源')),
          items: const [
            DropdownMenuItem(
              value: ModelSource.demo,
              child: LText('演示助手（固定规则）'),
            ),
            DropdownMenuItem(
              value: ModelSource.local,
              child: LText('本机模型（兼容 JSON）'),
            ),
            DropdownMenuItem(
              value: ModelSource.api,
              child: LText('通用 API（Chat Completions）'),
            ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  c.source = value!;
                  onChanged();
                },
        ),
        if (c.source != ModelSource.demo) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('model_endpoint'),
            controller: c.source == ModelSource.api
                ? c.apiEndpoint
                : c.localEndpoint,
            onChanged: (_) => onChanged(),
            enabled: !busy,
            decoration: const InputDecoration(
              label: LText('服务地址'),
              hint: LText('https://服务地址/v1/chat/completions'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('model_name'),
            controller: c.model,
            onChanged: (_) => onChanged(),
            enabled: !busy,
            decoration: const InputDecoration(label: LText('模型名称（按服务提供方填写）')),
          ),
          if (c.source == ModelSource.api) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('model_api_key'),
              controller: c.apiKey,
              onChanged: (_) => onChanged(),
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                label: LText('API 密钥（服务需要时填写）'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ApiReplyMode>(
              initialValue: c.replyMode,
              isExpanded: true,
              decoration: const InputDecoration(label: LText('接口模式')),
              items: const [
                DropdownMenuItem(
                  value: ApiReplyMode.tools,
                  child: LText('工具调用（推荐）'),
                ),
                DropdownMenuItem(
                  value: ApiReplyMode.json,
                  child: LText('兼容 JSON（无工具调用时）'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      c.replyMode = value!;
                      onChanged();
                    },
            ),
            const SizedBox(height: 8),
            LText('对话灵活度：${c.temperature.toStringAsFixed(1)}'),
            ControlSlider(
              value: c.temperature,
              divisions: 10,
              onChanged: busy
                  ? null
                  : (value) {
                      c.temperature = value;
                      onChanged();
                    },
            ),
            DropdownButtonFormField<int>(
              key: const Key('model_timeout'),
              initialValue: c.timeoutSeconds,
              decoration: const InputDecoration(label: LText('每次请求最长等待')),
              items: [
                for (final seconds in [15, 30, 60, 120])
                  DropdownMenuItem(value: seconds, child: LText('$seconds 秒')),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      c.timeoutSeconds = value!;
                      onChanged();
                    },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('model_tokens'),
              initialValue: c.maxTokens,
              decoration: const InputDecoration(label: LText('回复 token 上限')),
              items: [
                for (final tokens in [600, 1200, 2400])
                  DropdownMenuItem(value: tokens, child: LText('$tokens')),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      c.maxTokens = value!;
                      onChanged();
                    },
            ),
            const SizedBox(height: 8),
            const LText(
              '等待模型不会延长 30 秒控制授权；授权到期后，迟到的动作不会执行。',
              style: TextStyle(fontSize: 11),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('model_persona'),
            controller: c.persona,
            onChanged: (_) => onChanged(),
            enabled: !busy,
            maxLength: 1000,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              label: LText('对话偏好'),
              hint: LText('称呼、语气、话题偏好…'),
            ),
          ),
          const LText(
            'API 会收到最近对话、对话偏好和仿真状态。工具模式一次互动最多请求模型两次；服务费用按提供方规则计算。',
            style: TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('test_model'),
            onPressed: busy ? null : onTest,
            icon: const Icon(Icons.wifi_tethering, size: 16),
            label: const LText('测试模型连接（仅聊天）'),
          ),
          if (testStatus.isNotEmpty)
            LText(
              testStatus,
              key: const Key('model_test_status'),
              style: const TextStyle(fontSize: 12),
            ),
        ],
        const SizedBox(height: 8),
        const LText(
          '可在本机保存服务地址、模型和对话偏好。API 密钥、聊天记录和控制授权不会保存；重启后需要重新填写密钥。',
          style: TextStyle(fontSize: 11),
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('save_model_preferences'),
              onPressed: busy ? null : onSave,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const LText('保存配置与偏好'),
            ),
            TextButton(
              key: const Key('forget_model_preferences'),
              onPressed: busy ? null : onForget,
              child: const LText('删除已保存配置'),
            ),
          ],
        ),
        if (storageStatus.isNotEmpty)
          LText(
            storageStatus,
            key: const Key('preferences_status'),
            style: const TextStyle(fontSize: 11),
          ),
      ],
    );
  }
}
