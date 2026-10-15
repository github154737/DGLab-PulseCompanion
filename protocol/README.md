# Isolated protocol fixture

This is developer test infrastructure, not a production device bridge.
It registers only upstream Buttplug's simulated communication manager.
It binds a random IPv4 loopback port, accepts one client and exits after that client disconnects.
No physical hardware managers are linked or registered.

The API selection follows the BSD-3-Clause upstream documentation and simulated-device tests at:
https://github.com/buttplugio/buttplug/tree/intiface-engine-5.0.4

The app's normal builds do not depend on this separate Cargo workspace.
Run with the project protocol-test script after compiling this fixture.
