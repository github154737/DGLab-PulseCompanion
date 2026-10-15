import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_access.dart';
import 'venice_chat_page.dart';
import 'venice_route.dart';
import 'warm_theme.dart';
import 'service_connection.dart';

typedef PublicSessionBuilder = Widget Function(
  AppRole role,
  Future<String> Function() loadKey,
  VoidCallback close,
);

/// Public distributions carry no operator credential and never load desktop keys.
class PublicSetupGate extends StatefulWidget {
  const PublicSetupGate({
    super.key,
    this.initialDeveloperTools = false,
    this.sessionBuilder,
    this.readConnectionFile,
  });
  final bool initialDeveloperTools;
  final PublicSessionBuilder? sessionBuilder;
  final Future<List<int>?> Function()? readConnectionFile;
  @override
  State<PublicSetupGate> createState() => _PublicSetupGateState();
}

class _PublicSetupGateState extends State<PublicSetupGate> {
  final credential = TextEditingController();
  final address = TextEditingController();
  final certificate = TextEditingController();
  late bool developerTools = widget.initialDeveloperTools;
  bool relay = false, ready = false;
  String? sessionKey, error;
  GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  Future<void> importConnection() async {
    try {
      List<int>? bytes;
      if (widget.readConnectionFile != null) {
        bytes = await widget.readConnectionFile!();
      } else {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: '连接配置',
              extensions: const ['json'],
              mimeTypes: Platform.isAndroid ? const ['*/*'] : null,
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > ServiceConnection.maxBytes) {
          throw const FormatException();
        }
        bytes = await file.readAsBytes();
      }
      if (bytes == null || !mounted) return;
      final connection = ServiceConnection.parse(bytes);
      setState(() {
        relay = true;
        address.text = connection.url;
        credential.text = connection.token;
        certificate.text = connection.certificate;
        error = null;
      });
      // Import only fills the form. The user reviews the destination and enters.
    } catch (_) {
      if (mounted) setState(() => error = '连接文件无效，请向提供者索取有效的 JSON 连接文件。');
    }
  }

  @override
  void dispose() {
    credential.dispose();
    address.dispose();
    certificate.dispose();
    sessionKey = null;
    super.dispose();
  }

  void enter({bool offline = false}) {
    final key = credential.text.trim();
    try {
      if (!offline && key.isEmpty) throw const FormatException();
      if (!offline &&
          !relay &&
          !RegExp(r'^VENICE_INFERENCE_KEY_[A-Za-z0-9_-]+$').hasMatch(key)) {
        throw const FormatException();
      }
      var cert = certificate.text.trim();
      if (cert.startsWith('-----BEGIN CERTIFICATE-----')) {
        cert = base64Encode(utf8.encode(cert));
      }
      if (!offline && relay && address.text.trim().isEmpty) {
        throw const FormatException();
      }
      VeniceRoute.configurePublic(
        url: offline || !relay ? '' : address.text.trim(),
        token: offline || !relay ? '' : key,
        certificate: offline || !relay ? '' : cert,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        sessionKey = offline ? null : key;
        credential.clear();
        certificate.clear();
        navigator = GlobalKey<NavigatorState>();
        ready = true;
        error = null;
      });
    } catch (_) {
      setState(() => error = '配置无效，请检查密钥、HTTPS 地址和证书格式。');
    }
  }

  void close() {
    // VeniceChatPage invokes this only after cancellation and confirmed stop.
    VeniceRoute.configurePublic();
    setState(() {
      ready = false;
      sessionKey = null;
      error = null;
    });
  }

  Future<String> loadKey() async {
    if (sessionKey == null) throw StateError('key_missing');
    return sessionKey!;
  }

  @override
  Widget build(BuildContext context) {
    if (ready) {
      return NavigatorPopHandler<Object?>(
        onPopWithResult: (result) => navigator.currentState?.pop(result),
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) {
              final role = developerTools
                  ? AppRole.administrator
                  : AppRole.user;
              return widget.sessionBuilder?.call(role, loadKey, close) ??
                  VeniceChatPage(
                    role: role,
                    loadKey: loadKey,
                    onLogout: close,
                    selfHosted: true,
                  );
            },
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: RoseAvatar(size: 64)),
                  const SizedBox(height: 20),
                  Text(
                    '配置你的服务',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '有连接文件？导入后即可进入。自己使用 Venice？只需填写 API 密钥。配置仅在本次运行中保留。',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('public_import'),
                    onPressed: importConnection,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('导入连接文件'),
                  ),
                  SwitchListTile(
                    key: const Key('public_relay'),
                    contentPadding: EdgeInsets.zero,
                    value: relay,
                    title: const Text('使用自己的中继'),
                    onChanged: (value) => setState(() {
                      relay = value;
                      credential.clear();
                      error = null;
                    }),
                  ),
                  if (relay)
                    TextField(
                      key: const Key('public_address'),
                      controller: address,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'HTTPS 中继地址（含 /api/v1）',
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('public_credential'),
                    controller: credential,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: relay ? '中继访问令牌' : 'Venice API 密钥',
                    ),
                  ),
                  if (relay) ...[
                    const SizedBox(height: 12),
                    Text(
                      '将连接：${Uri.tryParse(address.text)?.host ?? ''}；请确认这是你信任的服务。',
                    ),
                    ExpansionTile(
                      title: const Text('高级：HTTPS 证书'),
                      children: [
                        TextField(
                          key: const Key('public_certificate'),
                          controller: certificate,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '可选：自签名证书 PEM 或 Base64',
                            helperText: '留空使用系统可信证书，始终验证 HTTPS',
                          ),
                        ),
                      ],
                    ),
                  ],
                  ExpansionTile(
                    key: const Key('public_advanced'),
                    title: const Text('开发选项'),
                    children: [
                      SwitchListTile(
                        key: const Key('public_developer_tools'),
                        contentPadding: EdgeInsets.zero,
                        value: developerTools,
                        onChanged: (value) =>
                            setState(() => developerTools = value),
                        title: const Text('开启本机开发工具'),
                        subtitle: const Text('显示模拟、诊断和模型设置；仅针对你自己的服务'),
                      ),
                    ],
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('public_enter'),
                    onPressed: enter,
                    child: const Text('进入应用'),
                  ),
                  TextButton(
                    key: const Key('public_offline'),
                    onPressed: () => enter(offline: true),
                    child: const Text('先离线浏览'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
