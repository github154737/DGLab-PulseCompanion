import 'package:flutter/material.dart';

class LanguageScope extends InheritedWidget {
  const LanguageScope({
    super.key,
    required this.language,
    required super.child,
  });
  final String language;
  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.language ??
      'zh';
  @override
  bool updateShouldNotify(LanguageScope oldWidget) =>
      language != oldWidget.language;
}

/// UI-owned strings only. Imported prose and conversation messages keep their text.
class LText extends StatelessWidget {
  const LText(
    this.data, {
    super.key,
    this.style,
    this.overflow,
    this.textAlign,
    this.maxLines,
    this.softWrap,
  });
  final String data;
  final TextStyle? style;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final int? maxLines;
  final bool? softWrap;
  @override
  Widget build(BuildContext context) => Text(
    translate(data, LanguageScope.of(context)),
    style: style,
    overflow: overflow,
    textAlign: textAlign,
    maxLines: maxLines,
    softWrap: softWrap,
  );
}

String translate(String text, String language) {
  if (language != 'en') return text;
  if (english.containsKey(text)) return english[text]!;
  var result = text;
  for (final entry in fragments.entries) {
    result = result.replaceAll(entry.key, entry.value);
  }
  return result;
}

const english = <String, String>{
  '触觉实验室': 'Haptics Lab',
  '体验': 'Session',
  '设备': 'Devices',
  '波形': 'Waveforms',
  '记录': 'Activity',
  '仅模拟': 'Simulation',
  '实物输出': 'Physical output',
  '立即停止': 'STOP',
  '选择设备': 'Select device',
  '本次授权': 'Session authorization',
  '与助手一起体验': 'Conversation & control',
  '看见每一次变化': 'Watch every change',
  '波形库': 'Waveform library',
  '外部设备连接': 'External device connection',
  '按协议读取实际设备能力': 'Discover actual device capabilities',
  '控制权始终在你手中': 'You remain in control',
  '保留最后模拟输出，停止状态未确认': 'Last output retained; stop unconfirmed',
  '开始对话体验': 'Start conversation session',
  '重新授权体验': 'Authorize a new session',
  '授权并开始': 'Authorize & start',
  '体验波形': 'Session waveform',
  '内置 · 柔和起伏': 'Built in · Gentle wave',
  '强一点': 'Stronger',
  '弱一点': 'Softer',
  '陪我聊聊': 'Talk with me',
  '播放导入波形': 'Play imported waveform',
  '输入想体验的节奏…': 'Describe a rhythm…',
  '清空聊天': 'Clear conversation',
  '柔和起伏': 'Gentle wave',
  '短脉冲': 'Soft pulse',
  '双通道交替': 'Alternating channels',
  '温柔': 'Gentle',
  '俏皮': 'Playful',
  '简洁': 'Concise',
  '模拟输出上限': 'Normalized output limit',
  '相对强度（在授权上限内）': 'Relative gain (within the authorized cap)',
  '剩余授权时间': 'Authorization remaining',
  '每次授权 30 秒 · 导入波形最长 20 秒': '30s authorization · imported waveforms up to 20s',
  '允许 AI 提议波形和相对强度': 'Allow AI waveform and gain proposals',
  '仍需本地授权。关闭会立即撤销待处理动作。':
      'Local authorization is required. Disabling revokes pending actions.',
  '循环仿真波形，直到本次授权到期或立即停止。':
      'Loop the waveform until authorization expires or you stop.',
  '先到设备页连接一个模拟器，再开始体验': 'Connect a simulator in Devices to begin.',
  '实际输出 = 波形幅度 × 相对强度 × 授权上限':
      'Output = waveform amplitude × relative gain × authorized cap',
  '默认使用模拟；实物输出需单独启用': 'Simulation is the default; physical output requires explicit activation.',
  '离开应用会撤销会话。数值仅用于仿真，不代表真实设备的安全强度。': 'Leaving the app revokes the session. Normalized values do not establish a safe physical intensity.',
  '上限与期限由本地控制核心执行': 'Caps and deadlines are enforced locally',
  '故障模拟': 'Fault simulation',
  '正常模拟': 'Normal simulation',
  '断线后保持最后输出': 'Retain output after disconnection',
  '停止无法确认': 'Stop cannot be confirmed',
  '断开连接': 'Disconnect',
  '复位虚拟设备': 'Reset simulator',
  '运行记录': 'Activity log',
  '仅记录控制事件；聊天内容不写入诊断记录':
      'Diagnostics contain control events, not chat messages.',
  '连接设备后，事件会显示在这里。': 'Device events will appear here.',
  '预览诊断报告': 'Preview diagnostics',
  '诊断报告预览': 'Diagnostic report',
  '复制报告': 'Copy report',
  '关闭': 'Close',
  '模型与对话设置': 'Model & conversation settings',
  '回复来源': 'Reply source',
  '演示助手（固定规则）': 'Demo assistant (fixed rules)',
  '本机模型（兼容 JSON）': 'Local model (JSON compatible)',
  '通用 API（Chat Completions）': 'Generic API (Chat Completions)',
  '服务地址': 'Service URL',
  '模型名称（按服务提供方填写）': 'Model name (from your provider)',
  'API 密钥（服务需要时填写）': 'API key (if required)',
  '接口模式': 'Interface mode',
  '工具调用（推荐）': 'Tool calling (recommended)',
  '兼容 JSON（无工具调用时）': 'JSON compatibility mode',
  '每次请求最长等待': 'Request timeout',
  '回复 token 上限': 'Response token limit',
  '对话偏好': 'Conversation preferences',
  '称呼、语气、话题偏好…': 'Name, tone and preferred topics…',
  '测试模型连接（仅聊天）': 'Test model (chat only)',
  '保存配置与偏好': 'Save configuration & preferences',
  '删除已保存配置': 'Delete saved configuration',
  '演示助手 · 固定规则，未接入大模型': 'Demo assistant · fixed rules, no language model',
  '本机模型 · 发送最近对话和仿真状态':
      'Local model · receives recent conversation and control state',
  'API 模型 · 发送最近对话和仿真状态到你填写的服务': 'API model · sends recent conversation and control state to your endpoint',
  '等待模型不会延长 30 秒控制授权；授权到期后，迟到的动作不会执行。': 'Waiting for a model does not extend authorization. Late actions are rejected after expiry.',
  'API 会收到最近对话、对话偏好和仿真状态。工具模式一次互动最多请求模型两次；服务费用按提供方规则计算。': 'The API receives recent conversation, preferences and control state. Tool mode makes at most two model requests per turn. Provider usage charges apply.',
  '可在本机保存服务地址、模型和对话偏好。API 密钥、聊天记录和控制授权不会保存；重启后需要重新填写密钥。': 'Endpoint, model and preferences can be stored locally. Keys, conversations and authorization are not saved. Re-enter your key after restarting.',
  'A/B 独立控制台': 'Independent A/B controls',
  '单通道强度、上限、波形与临时动作': 'Channel strength, caps, waveforms and timed actions',
  '启用通道': 'Enable channel',
  '临时保持': 'Temporary hold',
  '清除此通道': 'Clear this channel',
  '独立波形': 'Channel waveform',
  '在动作时长内循环': 'Repeat within the action duration',
  '24 种内置波形': '24 built-in waveforms',
  '原创参数化波形 · 可导出 JSON 预览': 'Original patterns · export JSON for preview',
  '导出波形': 'Export waveform',
  '复制 JSON': 'Copy JSON',
  '播放内置波形': 'Play built-in waveform',
  '通道强度与上限均为相对比例，继续受本次总上限约束。单次手动增加最多 20%，AI 增加最多 10%。': 'Channel gains and caps are relative and remain within the session cap. Manual increases are limited to 20 percentage points; AI increases to 10.',
  '连接方式': 'Connection type',
  'Intiface / 多品牌': 'Intiface / multiple brands',
  '郊狼 / DG-LAB 4': 'Coyote / DG-LAB 4',
  '连接服务': 'Connect service',
  '断开服务': 'Disconnect service',
  '刷新设备': 'Refresh devices',
  '扫描 5 秒': 'Scan for 5 seconds',
  'APP 配对链接': 'APP pairing link',
  '复制配对链接': 'Copy pairing link',
  '在本机打开 DG-LAB 配对': 'Pair with DG-LAB on this phone',
  '同一台手机即可：连接服务 → 打开 DG-LAB 配对 → 返回选择蓝牙设备 → 显式启用输出。DG-LAB 4 负责蓝牙连接；本页不会自动开启输出。': 'On one phone: connect the service, open DG-LAB pairing, return to select a Bluetooth device, then explicitly enable output. DG-LAB 4 handles Bluetooth; pairing never enables output.',
  '无需第二台手机。若先进入浏览器，请按官方页面提示打开 DG-LAB。配对期间请勿断开本页服务。': 'No second phone needed. If a browser opens, follow the official page to open DG-LAB. Keep this connection open while pairing.',
  '已打开官方配对页面；按页面提示进入 DG-LAB，完成后返回。打开页面不代表配对成功。': 'Official pairing page opened. Follow its instructions to open DG-LAB and return afterwards. Opening the page does not confirm pairing.',
  '未能打开配对页面。可复制链接粘贴到手机浏览器打开，并确认已安装 DG-LAB 4。': 'Could not open pairing. Copy the link into your browser and check that DG-LAB 4 is installed.',
  '已复制，可粘贴到手机浏览器打开。链接仅在本次连接期间有效。': 'Copied. Paste into your browser. Valid only for this connection.',
  '其他手机扫码 / 查看配对链接': 'Scan from another phone / View link',
  '二维码仅在本次连接期间有效，重新连接后请使用新链接。': 'Valid only for this connection. Use the new link after reconnecting.',
  '蓝牙已连接 · 点击选择，尚未授权输出': 'Bluetooth connected. Select to continue; output is not authorized.',
  '蓝牙未连接或状态未确认，请在 DG-LAB 中连接': 'Bluetooth disconnected or unconfirmed. Connect in DG-LAB.',
  '先启动同一设备上的 Intiface Central 服务，再连接。扫描需单独点击；支持情况以返回的能力为准。': 'Start Intiface Central on this device, then connect. Scanning is separate; support depends on discovered capabilities.',
  '先点击连接获得配对链接，再交给 DG-LAB 4 APP。只有连接与设备数据进入中继，聊天内容不发送给它。': 'Connect to obtain a pairing link for DG-LAB 4 APP. Only connection and device data go to the relay; chat stays separate.',
  '用 DG-LAB 4 APP 扫码配对。二维码仅在本次连接期间有效。': 'Scan using DG-LAB 4 APP. This code is valid for the current connection only.',
  '先预览再导入；导入不启动输出': 'Preview before importing; import never starts output',
  '导入 / 粘贴波形': 'Import / paste waveform',
  '导入后保存在本机，重启后恢复。最多 24 个波形。':
      'Imports are stored locally and restored on restart. Up to 24 waveforms.',
  '当前仅保留在会话内；可复制源文件留存':
      'Session-only storage; retain a copy of your source file',
  '编辑波形库前请停止当前会话': 'Stop the current session before editing the library',
  '模拟播放': 'Preview playback',
  '移除波形': 'Remove waveform',
  '导入波形 · 先校验再保存': 'Import waveform · validate before saving',
  '波形 JSON': 'Waveform JSON',
  '粘贴 JSON，或选择文件': 'Paste JSON or choose a file',
  '选择文件': 'Choose file',
  '通用示例': 'Envelope example',
  '郊狼示例': 'Coyote example',
  '输入是郊狼 V3 原始帧数组': 'Input is a raw Coyote V3 frame array',
  '波形 ID（英文、数字、_、-）': 'Waveform ID (letters, digits, _, -)',
  '校验预览': 'Validate & preview',
  '导入': 'Import',
  '取消': 'Cancel',
  '支持 envelope_v1 JSON 与 dglab_v3 帧封装。收到你的实际导出文件后再补对应解析器。': 'Supports envelope_v1 JSON and dglab_v3 frames. A vendor export parser can be added when a sample is available.',
  '郊狼频率参数与通道强度分别保留。预览只显示相对幅度，不向实体设备发送。': 'Frequency and amplitude are preserved separately. This preview alone does not send to hardware.',
  '尚无动作': 'No actions yet',
  '等待连接': 'Waiting for connection',
  '设备就绪 · 尚未授权': 'Device ready · not authorized',
  '已授权 · 等待动作': 'Authorized · waiting for an action',
  '已停止 · 等待重新授权': 'Stopped · new authorization required',
  '模拟预设执行中': 'Waveform playing',
  '停止状态未确认': 'Stop unconfirmed',
  '已连接': 'Connected',
  '尚未连接': 'Not connected',
  '已断开': 'Disconnected',
  '请先连接设备并授权': 'Connect and authorize first',
  '停止状态未知，需要复位虚拟设备': 'Stop state unknown; reset the simulator',
  '当前状态不能授权': 'Cannot authorize in the current state',
  '上一个预设还在执行': 'A preset is already playing',
  '当前设备不支持这个预设': 'Preset unsupported by this device',
  '旧请求已失效，已保留你最新的操作': 'Old request revoked; your latest action is preserved',
  '请求已失效': 'Request expired',
  '剩余授权时间不足，请停止后重新授权':
      'Not enough authorization time; stop and authorize again',
  'AI 每次最多上调 10 个百分点': 'AI may increase by at most 10 percentage points',
  '上调过于频繁，请稍后再试': 'Increases are too frequent; try again shortly',
  '此波形与当前模拟器类型或通道数不匹配':
      'Waveform format or channel count does not match the controller',
  '模型动作格式不符合要求': 'Invalid model action format',
  '模型指定的设备与当前设备不一致': 'Model device does not match the current device',
  '尚未授权或授权已到期 · 仅聊天': 'Not authorized or expired · chat only',
  '未连接模拟器 · 仅聊天': 'No controller connected · chat only',
  'AI 动作已关闭 · 仅聊天': 'AI actions disabled · chat only',
  '可在输入框外长按空格 1 秒停止': 'Hold Space outside a text field for one second to stop',
};
const fragments = <String, String>{
  '执行回执：': 'Action receipt: ',
  '本条执行回执：': 'This turn: ',
  '相对强度': 'Relative gain ',
  '通道相对强度：': 'Channel gain: ',
  '通道上限：': 'Channel cap: ',
  '对话灵活度：': 'Temperature: ',
  '动作时长：': 'Duration: ',
  ' 通道名称 / 配件备注': ' channel name / accessory note',
  '个已识别通道': 'recognized channels',
  '个模拟通道': 'controller channels',
  '已停止 · 授权及待处理动作已撤销': 'Stopped · authorization and pending actions revoked',
  '已应用到当前仿真波形': 'Applied to the current waveform',
  '已授权但未播放 · 剩余': 'Authorized, idle · remaining',
  '当前未播放，点击「开始对话体验」后生效': 'Idle; start a conversation session to apply',
  '连续仿真中': 'Continuous playback',
  '短波形播放中': 'Short waveform playing',
  '剩余': 'Remaining',
  ' 秒': ' seconds',
  '导入 · ': 'Imported · ',
  '仅聊天 · ': 'Chat only · ',
  '未执行 · ': 'Not executed · ',
  '未执行：': 'Not executed: ',
  '未开始 · ': 'Not started · ',
  '已执行 · ': 'Executed · ',
  '（仅仿真）': '(simulated)',
  '已启动短波形': 'Short waveform started',
  '连续体验已切换波形': 'Continuous waveform changed',
  '播放 ': 'Play ',
  ' 通道': ' channel',
  '正在恢复本机波形库，请稍候…': 'Restoring local waveforms…',
};
