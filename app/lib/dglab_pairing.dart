/// The official https://dungeon-lab.cn/s/ page forwards its raw query to
/// dglab4://s. Preserve the encoded nested WebSocket URL exactly once.
Uri dglabAppPairingUri(Uri web) {
  if (web.scheme != 'https' ||
      web.host != 'dungeon-lab.cn' ||
      web.path != '/s/' ||
      web.queryParameters['action'] != 'socket') {
    throw const FormatException('无效的 DG-LAB 配对链接');
  }
  return Uri.parse('dglab4://s?${web.query}');
}
