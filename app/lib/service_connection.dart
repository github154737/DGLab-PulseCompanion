import 'dart:convert';
import 'dart:io';

/// Portable connection file; never contains roles, prompts or device grants.
class ServiceConnection {
  const ServiceConnection(this.url, this.token, this.certificate);
  final String url, token, certificate;
  static const maxBytes = 32768;

  static ServiceConnection parse(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('连接文件大小无效');
    }
    final data = jsonDecode(utf8.decode(bytes));
    const allowed = {'format', 'version', 'url', 'token', 'certificate'};
    if (data is! Map<String, dynamic> ||
        data.keys.any((key) => !allowed.contains(key)) ||
        data['format'] != 'aihaptics-connection' ||
        data['version'] != 1 ||
        data['url'] is! String ||
        data['token'] is! String ||
        (data.containsKey('certificate') && data['certificate'] is! String)) {
      throw const FormatException('不支持的连接文件');
    }
    final url = (data['url'] as String).trim();
    final token = (data['token'] as String).trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token.isEmpty ||
        token.contains(RegExp(r'[\r\n]')) ||
        token.startsWith('VENICE_INFERENCE_KEY_')) {
      throw const FormatException('连接地址或令牌无效');
    }
    var cert = ((data['certificate'] ?? '') as String).trim();
    if (cert.startsWith('-----BEGIN CERTIFICATE-----')) {
      cert = base64Encode(utf8.encode(cert));
    }
    if (cert.isNotEmpty) {
      SecurityContext(withTrustedRoots: false)
          .setTrustedCertificatesBytes(base64Decode(cert));
    }
    return ServiceConnection(url, token, cert);
  }
}
