import 'dart:convert';
import 'dart:io';

class BetaApi {
  BetaApi(String address) : base = Uri.parse(address.trim()) {
    if (base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/') ||
        base.host.isEmpty ||
        (base.scheme != 'https' &&
            !(base.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '::1'].contains(base.host)))) {
      throw const FormatException('服务地址须为 HTTPS；本机测试可用 http://127.0.0.1:8790');
    }
  }
  final Uri base;
  String token = '';
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await http.openUrl(
        body == null ? 'GET' : 'POST',
        base.resolve(path),
      );
      req.followRedirects = false;
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw StateError('服务拒绝请求（${res.statusCode}），请检查邀请码、账号状态或额度');
      }
      final bytes = <int>[];
      await for (final part in res.timeout(const Duration(seconds: 10))) {
        if (bytes.length + part.length > 65536) {
          throw StateError('response_size');
        }
        bytes.addAll(part);
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      http.close(force: true);
    }
  }

  Future<void> redeem(String code) async {
    final reply = await request('/v1/redeem', body: {'code': code});
    token = reply['token'] as String;
  }

  Future<WebSocket> connect() async {
    if (token.isEmpty) throw StateError('请先兑换邀请码');
    final uri = base
        .resolve('/v1/realtime')
        .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    var expired = false;
    final future = WebSocket.connect(
      uri.toString(),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      customClient: http,
    );
    unawaitedConnectionCleanup(future, () => expired);
    try {
      return await future.timeout(const Duration(seconds: 15));
    } finally {
      expired = true;
      http.close(force: true);
    }
  }

  void unawaitedConnectionCleanup(
    Future<WebSocket> future,
    bool Function() expired,
  ) {
    future.then((socket) {
      if (expired()) socket.close();
    }, onError: (Object _) {});
  }
}
