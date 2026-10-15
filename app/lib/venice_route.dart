import 'dart:convert';
import 'dart:io';

import 'http_connection_pool.dart';

/// Build-time relay configuration. Never disables TLS verification.
class VeniceRoute {
  static final connections = HttpConnectionPool();
  static HttpClientLease lease(Uri uri, String credential) =>
      connections.acquire('${uri.origin}\n$credential', () => client(uri));
  static String? _runtimeUrl, _runtimeToken, _runtimeCertificate, _runtimeKind;
  static String get relayUrl =>
      _runtimeUrl ?? const String.fromEnvironment('VENICE_RELAY_URL');
  static String get relayToken =>
      _runtimeToken ?? const String.fromEnvironment('VENICE_RELAY_TOKEN');
  static String get relayCertificate =>
      _runtimeCertificate ?? const String.fromEnvironment('VENICE_RELAY_CERT');
  static String get relayKind =>
      _runtimeKind ??
      const String.fromEnvironment('VENICE_RELAY_KIND', defaultValue: 'local');

  /// Only the public self-host setup may override a route. Never persists secrets.
  static void configurePublic({
    String url = '',
    String token = '',
    String certificate = '',
  }) {
    if (const String.fromEnvironment('APP_EDITION', defaultValue: 'public') !=
        'public') {
      throw StateError('private_route_is_fixed');
    }
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          token.trim().isEmpty ||
          token.startsWith('VENICE_INFERENCE_KEY_') ||
          token.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('请填写 HTTPS 中继地址和访问令牌');
      }
      if (certificate.isNotEmpty) {
        // Validate before changing global state. Invalid certificates fail closed.
        SecurityContext(withTrustedRoots: false)
            .setTrustedCertificatesBytes(base64Decode(certificate));
      }
    } else if (token.isNotEmpty || certificate.isNotEmpty) {
      throw const FormatException('直连模式不能携带中继配置');
    }
    connections.invalidate();
    _runtimeUrl = url;
    _runtimeToken = token;
    _runtimeCertificate = certificate;
    _runtimeKind = 'cloud';
  }

  static bool get isRelay => relayUrl.isNotEmpty;
  static bool get isCloudRelay => isRelay && relayKind == 'cloud';
  static String get connectionLabel => isCloudRelay
      ? '经云中继 · 无需电脑在线'
      : isRelay
      ? '经本机中继 · 手机无需 VPN'
      : '手机直连 Venice';
  static String get timeoutMessage => isCloudRelay
      ? '云中继连接超时，请检查手机网络或切换 Wi-Fi／移动网络；若持续失败，请检查云服务状态。'
      : isRelay
      ? '中继连接超时。请确认同一 Wi-Fi、电脑中继已启动，以及防火墙和 VPN 允许局域网访问。'
      : '连接检测超时，请检查手机网络。';
  static String get networkFailureMessage => isRelay
      ? '中继网络连接失败。请检查手机网络与中继服务状态。'
      : '域名解析或网络连接失败。请在这台手机上检查 Venice 是否可访问。';
  static Uri get base =>
      Uri.parse(isRelay ? relayUrl : 'https://api.venice.ai/api/v1');
  static Uri endpoint(String path) =>
      Uri.parse('${base.toString().replaceFirst(RegExp(r'/+$'), '')}/$path');
  static String get description => isCloudRelay
      ? '手机 → 云中继 → Venice；无需电脑开机或同一 Wi-Fi。手机网络须能访问云中继。'
      : isRelay
      ? '手机 → 本机中继 → Venice；电脑须保持开机、VPN 和中继运行，手机使用同一 Wi-Fi。'
      : '手机直连 Venice，不依赖电脑后端。';
  static bool accepts(Uri uri) =>
      isRelay &&
      uri.scheme == 'https' &&
      uri.origin == base.origin &&
      {
        endpoint('audio/transcriptions').path,
        endpoint('audio/speech').path,
      }.contains(uri.path);
  static HttpClient client(Uri uri) {
    if (isRelay && uri.origin == base.origin) {
      if (base.scheme != 'https' ||
          relayToken.isEmpty ||
          (relayCertificate.isEmpty && _runtimeUrl == null)) {
        throw StateError('relay_configuration_invalid');
      }
      final context = SecurityContext(
        withTrustedRoots: relayCertificate.isEmpty,
      );
      if (relayCertificate.isNotEmpty) {
        context.setTrustedCertificatesBytes(base64Decode(relayCertificate));
      }
      return HttpClient(context: context)..findProxy = (_) => 'DIRECT';
    }
    return HttpClient();
  }
}
