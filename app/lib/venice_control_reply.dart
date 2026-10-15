import 'dart:async';
import 'dart:convert';

import 'api_model_provider.dart';

/// Strict protocol decoding. Never extract an action from chat prose or repair
/// incomplete JSON: the local session must only receive an unambiguous command.
Map<String, dynamic> decodeControlReply(String source) {
  final dynamic value;
  try {
    value = jsonDecode(source);
  } on FormatException {
    throw const ControlReplyFailure('invalid_json', '控制模型返回了非 JSON 或不完整 JSON');
  }
  if (value is! Map<String, dynamic>) {
    throw const ControlReplyFailure('invalid_command', '控制回复不是指令对象');
  }
  final action = value['action'];
  if ((action == 'hold' || action == 'stop') && value.length == 1) {
    return value;
  }
  if (action == 'set' &&
      value.length == 4 &&
      value['a'] is int &&
      value['b'] is int &&
      value['waveform_id'] is String) {
    return value;
  }
  throw const ControlReplyFailure('invalid_command', '控制指令的动作或字段格式不正确');
}

class ControlReplyFailure implements Exception {
  const ControlReplyFailure(this.code, this.label);
  final String code;
  final String label;

  /// Only allowlisted categories/numeric HTTP statuses reach UI or diagnostics.
  /// Do not expose server responses, transcripts, credentials or raw errors.
  static ControlReplyFailure from(Object error) {
    if (error is ControlReplyFailure) return error;
    if (error is TimeoutException) {
      return const ControlReplyFailure('timeout', '控制请求超时');
    }
    if (error is ModelServiceException) {
      final match = RegExp(r'^http_([1-5][0-9]{2})$').firstMatch(error.code);
      if (match != null) {
        return ControlReplyFailure(error.code, '控制接口返回 HTTP ${match[1]}');
      }
      const labels = {
        'timeout': '控制请求超时',
        'tls': '控制请求的 HTTPS 安全连接失败',
        'network': '控制请求无法连接服务',
        'transport': '控制请求传输失败',
        'cancelled': '控制请求已取消',
        'truncated': '控制回复达到长度上限，被截断',
        'content_filter': '服务未提供控制回复（内容过滤）',
        'model_response': '控制接口响应结构不完整或不兼容',
      };
      if (labels.containsKey(error.code)) {
        return ControlReplyFailure(error.code, labels[error.code]!);
      }
    }
    return const ControlReplyFailure('unexpected', '控制处理出现异常');
  }
}
