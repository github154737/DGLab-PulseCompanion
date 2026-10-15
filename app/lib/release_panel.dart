import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'experience_hub.dart';
import 'story_engine.dart';
import 'character.dart';

const appVersion = '0.6.2';

class ReleaseManifest {
  ReleaseManifest(this.version, this.notes, this.url);
  final String version, notes;
  final Uri url;
  factory ReleaseManifest.parse(Object? value) {
    final p = object(value, {
      'format',
      'version',
      'announcement',
      'download_url',
    });
    if (p['format'] != 'haptics_release_v1') {
      throw const FormatException('发行清单格式不支持');
    }
    final version = boundedText(p['version'], 40),
        notes = boundedText(p['announcement'], 4000, empty: true),
        url = Uri.parse(boundedText(p['download_url'], 2048));
    versionParts(version);
    if (url.scheme != 'https' || url.host.isEmpty || url.userInfo.isNotEmpty) {
      throw const FormatException('下载地址必须为 HTTPS');
    }
    return ReleaseManifest(version, notes, url);
  }
  bool get newer {
    final candidate = versionParts(version), current = versionParts(appVersion);
    for (var i = 0; i < 3; i++) {
      if (candidate[i] != current[i]) return candidate[i] > current[i];
    }
    return false;
  }
}

List<int> versionParts(String version) {
  if (!RegExp(r'^\d{1,5}\.\d{1,5}\.\d{1,5}$').hasMatch(version)) {
    throw const FormatException('版本号格式不正确');
  }
  return version.split('.').map(int.parse).toList();
}

Future<ReleaseManifest> fetchRelease(Uri uri) async {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入无凭据、无查询参数的 HTTPS 发行清单地址');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    return await (() async {
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      final response = await req.close();
      if (response.statusCode != 200) throw const FormatException('发行服务器暂不可用');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 16384) {
          throw const FormatException('发行清单过大');
        }
        bytes.addAll(chunk);
      }
      return ReleaseManifest.parse(jsonDecode(utf8.decode(bytes)));
    })().timeout(const Duration(seconds: 12));
  } finally {
    client.close(force: true);
  }
}

class ReleasePanel extends StatefulWidget {
  const ReleasePanel({super.key, required this.hub});
  final ExperienceHub hub;
  @override
  State<ReleasePanel> createState() => _ReleasePanelState();
}

class _ReleasePanelState extends State<ReleasePanel> {
  final endpoint = TextEditingController();
  bool busy = false;
  String status = '';
  ReleaseManifest? manifest;
  bool restored = false;
  String t(String zh, String en) => widget.hub.tr(zh, en);
  @override
  void initState() {
    super.initState();
    widget.hub.addListener(restore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) restore();
    });
  }

  void restore() {
    if (!mounted || widget.hub.loading || restored) return;
    restored = true;
    endpoint.text = widget.hub.releaseFeed;
    if (widget.hub.autoCheckUpdates &&
        endpoint.text.isNotEmpty &&
        !widget.hub.checkedUpdates) {
      widget.hub.checkedUpdates = true;
      check();
    }
  }

  Future<void> saveFeed() async {
    try {
      final text = endpoint.text.trim();
      if (text.isNotEmpty) {
        final uri = Uri.parse(text);
        if (uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment) {
          throw const FormatException(
            '请输入无凭据的 HTTPS 清单地址 / Use a credential-free HTTPS manifest URL',
          );
        }
      }
      widget.hub.releaseFeed = text;
      await widget.hub.saveSettings();
      if (mounted) {
        setState(() => status = t('发行设置已保存', 'Release settings saved'));
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  @override
  void dispose() {
    widget.hub.removeListener(restore);
    endpoint.dispose();
    super.dispose();
  }

  Future<void> check() async {
    if (busy) return;
    setState(() {
      busy = true;
      manifest = null;
      status = '';
    });
    try {
      final result = await fetchRelease(Uri.parse(endpoint.text.trim()));
      if (mounted) {
        setState(() {
          manifest = result;
          status = result.newer
              ? t('发现新版本 ${result.version}', 'New version ${result.version}')
              : t('当前已是此清单中的最新版本', 'Up to date with this manifest');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => status = e is FormatException
              ? e.message
              : t('检查失败，请确认发行地址', 'Check failed; verify the release URL'),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.hub,
    builder: (context, _) => Card(
      child: Column(
        children: [
          ExpansionTile(
            key: ValueKey('guide-${widget.hub.guideDone}'),
            initiallyExpanded: !widget.hub.guideDone,
            title: Text(t('开始使用 / 操作引导', 'Getting started')),
            childrenPadding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  '1. 先选模拟器与总上限，开始对话体验。\n2. 在模型设置中填服务地址、模型名和密钥；先测试连接，再保存非敏感配置。\n3. 选择角色，按需导入波形或内容包。\n4. 实物：DG-LAB 4 APP 连接郊狼 3.0 后，扫描配对码，选设备、设 A/B 硬上限，再显式启用输出。\n5. 停止按钮随时可用；输入框外长按空格 1 秒也可停止。\n6. 摄像头、麦克风、自动回合均需分别开启。',
                  '1. Choose a simulator and limit, then start a conversation session.\n2. Configure your endpoint, model and API key. Test the connection before saving non-secret preferences.\n3. Select a character; import waveforms or content as needed.\n4. Hardware: connect Coyote 3.0 in DG-LAB 4 APP, scan the pairing code, select the device, set A/B hard caps, then enable output.\n5. Stop is always available. Hold Space for one second outside text fields to stop.\n6. Camera, microphone and automatic rounds each require explicit activation.',
                ),
              ),
              TextButton(
                onPressed: widget.hub.loading
                    ? null
                    : () async {
                        widget.hub.guideDone = true;
                        try {
                          await widget.hub.saveSettings();
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => status = t(
                                '引导状态未能保存',
                                'Could not save guide preference',
                              ),
                            );
                          }
                        }
                      },
                child: Text(t('完成引导', 'Finish guide')),
              ),
            ],
          ),
          ExpansionTile(
            title: Text(t('版本与公告', 'Version & announcements')),
            subtitle: const Text('AI Haptics Lab $appVersion'),
            childrenPadding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  '当前为本机开发版。可填写本项目的 HTTPS 发行清单地址手动检查；不会自动下载或安装。',
                  'This is a local development build. Enter a project release manifest URL to check manually. Downloads and installation never start automatically.',
                ),
              ),
              TextField(
                controller: endpoint,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: t('发行清单地址', 'Release manifest URL'),
                  hintText: 'https://example.org/haptics-release.json',
                ),
              ),
              TextButton(
                onPressed: busy ? null : check,
                child: Text(t('检查版本与公告', 'Check version & announcements')),
              ),
              SwitchListTile(
                value: widget.hub.autoCheckUpdates,
                onChanged: busy
                    ? null
                    : (v) => setState(() => widget.hub.autoCheckUpdates = v),
                title: Text(
                  t('启动时检查（保存后生效）', 'Check at startup (save to apply)'),
                ),
              ),
              TextButton(
                onPressed: busy || widget.hub.loading ? null : saveFeed,
                child: Text(t('保存发行设置', 'Save release settings')),
              ),
              if (manifest != null) ...[
                SelectableText(manifest!.notes),
                SelectableText(manifest!.url.host),
                TextButton(
                  onPressed: () async {
                    try {
                      if (!await launchUrl(
                        manifest!.url,
                        mode: LaunchMode.externalApplication,
                      )) {
                        throw StateError('unavailable');
                      }
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => status = t(
                            '无法打开下载页面',
                            'Unable to open download page',
                          ),
                        );
                      }
                    }
                  },
                  child: Text(t('打开下载页面', 'Open download page')),
                ),
              ],
              Text(status),
            ],
          ),
        ],
      ),
    ),
  );
}
