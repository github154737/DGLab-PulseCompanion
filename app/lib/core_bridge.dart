import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _RequestNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _RequestDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class CoreBridge {
  CoreBridge({String? libraryPath}) {
    final override =
        libraryPath ?? Platform.environment['HAPTICS_CORE_LIBRARY'];
    final path =
        override ??
        (Platform.isWindows
            ? '${File(Platform.resolvedExecutable).parent.path}\\haptics_core.dll'
            : 'libhaptics_core.so');
    final library = DynamicLibrary.open(path);
    _request = library.lookupFunction<_RequestNative, _RequestDart>(
      'haptics_request',
    );
    _free = library.lookupFunction<_FreeNative, _FreeDart>('haptics_free');
  }
  late final _RequestDart _request;
  late final _FreeDart _free;
  Map<String, dynamic> call(Map<String, dynamic> request) {
    final data = jsonEncode(request);
    if (utf8.encode(data).length > 65536) {
      throw const FormatException('request_too_large');
    }
    final input = data.toNativeUtf8();
    Pointer<Utf8>? output;
    try {
      output = _request(input);
      if (output == nullptr) throw StateError('core_unavailable');
      return jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      calloc.free(input);
      if (output != null && output != nullptr) _free(output);
    }
  }
}
