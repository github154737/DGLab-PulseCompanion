import 'package:flutter_test/flutter_test.dart';
import 'package:haptics_lab/network_diagnostics.dart';
import 'package:haptics_lab/venice_wave_session.dart';
import 'package:haptics_lab/warm_interaction.dart';

void main() {
  test(
    'manual change explains old-ticket rejection without changing authority',
    () {
      NetworkTrace.clear();
      final session = VeniceWaveSession()..grant();
      final ticket = session.epoch;
      adjustWarmChannel(session, 0, 1);
      final receipt = session.apply({'action': 'hold'}, ticket);
      expect(receipt, contains('授权失效或请求已过期'));
      expect(session.active, true);
      expect(session.strength, [1, 0]);
      expect(NetworkTrace.report, contains('manual_strength'));
      expect(NetworkTrace.report, contains('ticket=$ticket'));
      expect(NetworkTrace.report, contains('active=true'));
      session.dispose();
    },
  );
  test(
    'network success is hidden but failures and control evidence remain',
    () {
      NetworkTrace.clear();
      final network = NetworkTrace('文字');
      network.mark('HTTPS 连接成功');
      network.mark('HTTP 200');
      network.mark('HTTP 502');
      NetworkTrace('控制轮次').mark('规划返回 action=hold');
      expect(NetworkTrace.report, isNot(contains('HTTP 200')));
      expect(NetworkTrace.report, isNot(contains('HTTPS 连接成功')));
      expect(NetworkTrace.report, contains('HTTP 502'));
      expect(NetworkTrace.report, contains('action=hold'));
      NetworkTrace.clear();
      expect(NetworkTrace.report, isNot(contains('action=hold')));
    },
  );
}
