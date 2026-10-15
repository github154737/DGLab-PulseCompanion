/// Sentence gate shared by visible streaming text and speech. No raw model
/// clause reaches either surface before this check. This is conservative rule
/// matching, not a claim of complete semantic verification.
class ControlReplyGuard {
  ControlReplyGuard({required this.fallback, this.onReplacement});
  final String Function() fallback;
  final void Function()? onReplacement;
  String _raw = '', text = '';
  int _offset = 0;
  bool _replaced = false;

  static bool claimsAction(String sentence) {
    final clauses = sentence.split(RegExp(r'[，,；;]'));
    if (clauses.length > 1) return clauses.any(claimsAction);
    final numericState = RegExp(
      r'(?:[ABab]\s*(?:通道)?\s*(?:=|是|为|已到)|强度\s*(?:是|为|已经到))\s*\d+',
    ).hasMatch(sentence);
    final shortCompletion = RegExp(
      r'(?:已经|已).{0,4}(?:换|加|调|减)(?:好了|了)[。！!\s]*$',
    ).hasMatch(sentence);
    // Future proposals are left intact only if there is no completion claim.
    final completed = RegExp(
      r'已经|已将|已把|已调|已换|已增加|已降低|已停止|已完成|调好了|换好了|设置好了|调高了|调低了|调大了|调小了|加上去了|提高了|降低了|增加了|减少了|换成了|停止了|归零了|现在.{0,8}(更强|更弱|强度|波形|调到|调高)|(?:调到|设为|设置为)\s*\d+\s*了|(?:have |has |already )?(?:increased|decreased|changed|set|stopped)\b',
      caseSensitive: false,
    ).hasMatch(sentence);
    final device = RegExp(
      r'强度|波形|通道|设备|电流|输出|调高|调低|调大|调小|调到|调好|换好|换成|加上去|归零|提高|降低|增加|减少|停止|更强|更弱|设置|\b[AB]\b|intensity|waveform|channel|device|output',
      caseSensitive: false,
    ).hasMatch(sentence);
    // Explicit negative outcomes should remain readable, but not shield a
    // subsequent contradictory positive clause in the same sentence.
    if (RegExp(
      r'没有|没能|未能|尚未|不能|不会|并未|not |never ',
      caseSensitive: false,
    ).hasMatch(sentence)) {
      return false;
    }
    return completed && device || numericState || shortCompletion;
  }

  String add(String value, {bool complete = false}) {
    if (!value.startsWith(_raw)) {
      throw const FormatException('non_append_reply');
    }
    _raw = value;
    for (var i = _offset; i < value.length; i++) {
      if ('。！？!?\n'.contains(value[i])) {
        _emit(value.substring(_offset, i + 1));
        _offset = i + 1;
      }
    }
    if (complete && _offset < value.length) {
      _emit(value.substring(_offset));
      _offset = value.length;
    }
    return text;
  }

  void _emit(String sentence) {
    if (claimsAction(sentence)) {
      onReplacement?.call();
      if (!_replaced) text += fallback();
      _replaced = true;
    } else {
      text += sentence;
    }
  }
}
