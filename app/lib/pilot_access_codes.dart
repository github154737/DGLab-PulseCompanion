// Private builds inject hashes from external configuration. Empty values deny access.
const pilotAdminCodeHash = String.fromEnvironment('PILOT_ADMIN_HASH');
const pilotUserCodeHashList = String.fromEnvironment('PILOT_USER_HASHES');
final pilotUserCodeHashes = pilotUserCodeHashList
    .split(',')
    .where((value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value))
    .toList(growable: false);
