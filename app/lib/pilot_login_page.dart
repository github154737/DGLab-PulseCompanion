import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_access.dart';
import 'warm_theme.dart';

typedef PilotAuthenticatedBuilder = Widget Function(
  BuildContext context,
  AppRole role,
  VoidCallback logout,
);

/// Mount after the splash. Each successful login gets a fresh navigation tree.
class PilotLoginGate extends StatefulWidget {
  const PilotLoginGate({
    super.key,
    required this.builder,
    this.accessController,
  });

  final PilotAuthenticatedBuilder builder;
  final PilotAccessController? accessController;

  @override
  State<PilotLoginGate> createState() => _PilotLoginGateState();
}

class _PilotLoginGateState extends State<PilotLoginGate> {
  late final PilotAccessController access =
      widget.accessController ?? PilotAccessController();
  final input = TextEditingController();
  GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
  AppRole selectedRole = AppRole.user;
  AppRole? authenticatedRole;
  bool hidden = true;
  String? error;
  Timer? cooldownTimer;

  @override
  void dispose() {
    cooldownTimer?.cancel();
    input.dispose();
    super.dispose();
  }

  void selectRole(AppRole role) {
    if (role == selectedRole) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      selectedRole = role;
      input.clear();
      error = null;
      hidden = true;
    });
  }

  void submit() {
    final result = access.attempt(selectedRole, input.text);
    if (result == PilotAccessAttempt.accepted) {
      FocusManager.instance.primaryFocus?.unfocus();
      cooldownTimer?.cancel();
      cooldownTimer = null;
      setState(() {
        input.clear();
        error = null;
        hidden = true;
        navigator = GlobalKey<NavigatorState>();
        authenticatedRole = selectedRole;
      });
      return;
    }
    setState(() {
      error = result == PilotAccessAttempt.locked
          ? null
          : selectedRole == AppRole.user
          ? '内测码不正确，请检查后重试'
          : '管理员密钥不正确，请检查后重试';
    });
    if (result == PilotAccessAttempt.locked) {
      cooldownTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (access.remaining == Duration.zero) {
          cooldownTimer?.cancel();
          cooldownTimer = null;
        }
      });
    }
  }

  void logout() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      authenticatedRole = null;
      selectedRole = AppRole.user;
      input.clear();
      error = null;
      hidden = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final role = authenticatedRole;
    if (role != null) {
      return NavigatorPopHandler<Object?>(
        onPopWithResult: (result) => navigator.currentState?.pop(result),
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => widget.builder(context, role, logout),
          ),
        ),
      );
    }
    final remaining = access.remainingSeconds;
    final status = remaining > 0 ? '尝试次数较多，请 $remaining 秒后重试' : error;
    return PopScope(
      canPop: false,
      child: Scaffold(
        key: const Key('pilot_login'),
        backgroundColor: warmPaper,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(0, constraints.maxHeight - 48),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const RoseAvatar(size: 76),
                        const SizedBox(height: 20),
                        Text(
                          'AI Haptics',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '让每一次互动，都有回应',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: warmMuted),
                        ),
                        const SizedBox(height: 32),
                        WarmCard(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              rolePicker(context),
                              const SizedBox(height: 28),
                              Text(
                                selectedRole == AppRole.user ? '欢迎来体验' : '欢迎回来',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                selectedRole == AppRole.user
                                    ? '输入你的内测码，开始聊天与互动。'
                                    : '验证身份后，进入管理与测试空间。',
                                style: const TextStyle(color: warmMuted),
                              ),
                              const SizedBox(height: 24),
                              TextField(
                                key: const Key('pilot_credential'),
                                controller: input,
                                obscureText: hidden,
                                autocorrect: false,
                                enableSuggestions: false,
                                enableIMEPersonalizedLearning: false,
                                smartDashesType: SmartDashesType.disabled,
                                smartQuotesType: SmartQuotesType.disabled,
                                textInputAction: TextInputAction.done,
                                textCapitalization: selectedRole == AppRole.user
                                    ? TextCapitalization.characters
                                    : TextCapitalization.none,
                                maxLength: selectedRole == AppRole.user
                                    ? 12
                                    : 128,
                                decoration: InputDecoration(
                                  labelText: selectedRole == AppRole.user
                                      ? '内测码'
                                      : '管理员密钥',
                                  hintText: selectedRole == AppRole.user
                                      ? '输入 10 位内测码'
                                      : '输入管理员密钥',
                                  counterText: '',
                                  suffixIcon: IconButton(
                                    key: const Key('pilot_toggle_secret'),
                                    tooltip: hidden ? '显示输入' : '隐藏输入',
                                    onPressed: () =>
                                        setState(() => hidden = !hidden),
                                    icon: Icon(
                                      hidden
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                  ),
                                ),
                                onChanged: (_) {
                                  if (error != null) {
                                    setState(() => error = null);
                                  }
                                },
                                onSubmitted: (_) => submit(),
                              ),
                              if (status != null) ...[
                                const SizedBox(height: 12),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    status,
                                    key: const Key('pilot_login_error'),
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 24),
                              FilledButton(
                                key: const Key('pilot_submit'),
                                onPressed: remaining > 0 ? null : submit,
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                    horizontal: 16,
                                  ),
                                ),
                                child: Text(
                                  remaining > 0
                                      ? '请稍候（$remaining 秒）'
                                      : selectedRole == AppRole.user
                                      ? '开始体验'
                                      : '管理员登录',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          '邀请内测 · 仅限受邀用户',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: warmMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget rolePicker(BuildContext context) {
    final roles = [
      roleChoice(AppRole.user, Icons.person_outline, '用户登录'),
      roleChoice(
        AppRole.administrator,
        Icons.admin_panel_settings_outlined,
        '管理员登录',
      ),
    ];
    if (MediaQuery.textScalerOf(context).scale(14) > 20) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [roles[0], const SizedBox(height: 8), roles[1]],
      );
    }
    return Row(
      children: [
        Expanded(child: roles[0]),
        const SizedBox(width: 8),
        Expanded(child: roles[1]),
      ],
    );
  }

  Widget roleChoice(AppRole role, IconData icon, String label) {
    final selected = selectedRole == role;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? const Color(0xFFF0DCE0) : warmPaper,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('pilot_role_${role.name}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => selectRole(role),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: selected ? warmRose : warmMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: selected ? warmRose : warmMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
