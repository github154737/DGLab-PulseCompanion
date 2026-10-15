import 'venice_route.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only controlled stage names and numeric status codes enter this buffer.
/// No request bodies, headers, credentials, transcripts or raw exceptions.
class NetworkTrace {
  static final List<String> _events = [];
  static int _sequence = 0;
  final String requestId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_sequence}';
  void attach(HttpClientRequest request) =>
      request.headers.set('X-AIHaptics-Request-Id', requestId);
  final String kind;
  final Stopwatch clock = Stopwatch()..start();
  String stage = '建立连接';
  NetworkTrace(this.kind) {
    mark(stage);
  }
  void mark(String value) {
    stage = value;
    // Keep control evidence and failures; suppress routine network chatter.
    final important = const {
      '控制状态',
      '控制轮次',
      '控制结果',
      '聊天核对',
      '对话导答',
      '持续对话',
      '测试边界',
      '设备配对',
      '实物输出',
    }.contains(kind);
    if (value == '建立连接') return;
    if (!important &&
        !RegExp(r'失败|错误|异常|超时|未完成|中断|HTTP [345]\d\d|详细原因').hasMatch(value)) {
      return;
    }
    _events.add(
      '${DateTime.now().toIso8601String()} $kind ${clock.elapsedMilliseconds}ms [$requestId] $value',
    );
    if (_events.length > 1200) _events.removeAt(0);
  }

  /// Accept diagnostic headers only from the configured, certificate-verified
  /// relay. Never copy upstream response bodies or arbitrary header values.
  String? relayResponse(HttpClientResponse response, Uri endpoint) {
    if (!VeniceRoute.isRelay || endpoint.origin != VeniceRoute.base.origin) {
      return null;
    }
    final headers = response.headers;
    final version = headers.value('x-aihaptics-relay-version');
    if (const ['0.10.3', '0.12.0', '0.12.1', '0.12.2'].contains(version)) {
      mark('中继版本 $version');
    }
    final capabilities =
        headers.value('x-aihaptics-relay-capabilities')?.split(',') ??
        const <String>[];
    if (capabilities.contains('speech')) {
      mark('中继支持语音输出');
    }
    if (capabilities.contains('speech-stream')) mark('中继支持流式语音');
    if (headers.value('x-aihaptics-relay-attempts') == '2') mark('中继已重试 1 次');
    const details = {
      'invalid_mp3': '音频头无效',
      'empty_stream': '空音频或音频头不足 32 字节',
      'stream_too_large': '流超过大小限制',
      'audio_content_type': '上游音频类型不符',
      'format_unspecified': '其他格式解析异常',
    };
    final detail = details[headers.value('x-aihaptics-relay-detail')];
    if (detail != null) mark('中继详细原因：$detail');
    const stages = {
      'client_upload': '手机上传到中继',
      'upstream_connect': '中继连接 Venice',
      'upstream_response': '等待 Venice 响应',
      'upstream_read': '读取 Venice 响应',
    };
    const errors = {
      'timeout': '超时',
      'socket': '网络连接失败',
      'upstream_tls': 'TLS 安全连接失败',
      'http_transport': '连接中断',
      'upstream_http': 'Venice 返回错误状态',
      'unexpected': '中继处理异常',
      'relay_rejected': '中继拒绝请求',
      'upstream_audio_invalid': 'Venice 未返回有效音频',
      'upstream_response_too_large': 'Venice 响应超过大小限制',
      'upstream_response_invalid': 'Venice 响应格式异常',
    };
    final stage = stages[headers.value('x-aihaptics-relay-stage')];
    final error = errors[headers.value('x-aihaptics-relay-error')];
    if (stage == null || error == null) return null;
    mark('中继：$stage · $error');
    if (response.statusCode < 500) return null;
    return '$stage：$error（HTTP ${response.statusCode}）。${VeniceRoute.isCloudRelay ? '请检查云中继与上游连接' : '请检查电脑 VPN 与中继'}；可手动重试。';
  }

  static void clear() => _events.clear();

  static String get report =>
      '控制与对话诊断 · 客户端 ${const String.fromEnvironment("APP_VERSION", defaultValue: "0.14.5")}\n最近 1200 条 · 不含录音、正文或密钥 · 常规网络阶段已隐藏\n${_events.join('\n')}';
}

class ConnectionDiagnostics extends StatefulWidget {
  const ConnectionDiagnostics({
    super.key,
    required this.apiKey,
    this.developerAccess = false,
  });
  final String? apiKey;
  final bool developerAccess;
  @override
  State<ConnectionDiagnostics> createState() => _ConnectionDiagnosticsState();
}

class _ConnectionDiagnosticsState extends State<ConnectionDiagnostics> {
  @override
  Widget build(BuildContext context) => !widget.developerAccess
      ? Scaffold(
          appBar: AppBar(title: const Text('访问受限')),
          body: const Center(child: Text('此功能仅限管理员使用')),
        )
      : Scaffold(
          appBar: AppBar(title: const Text('控制与对话诊断')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '先复现问题，再刷新并复制诊断。记录控制请求、对话导答、状态变化、执行结果和聊天回执核对；不主动发起网络测试。',
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {}),
                      child: const Text('刷新记录'),
                    ),
                    TextButton(
                      onPressed: () {
                        NetworkTrace.clear();
                        setState(() {});
                      },
                      child: const Text('清空，开始新测试'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: NetworkTrace.report),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制诊断，不含密钥与对话正文')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('复制诊断'),
                    ),
                  ],
                ),
                SelectableText(NetworkTrace.report),
              ],
            ),
          ),
        );
}
