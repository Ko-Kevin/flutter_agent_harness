// FA_OUTLOOK_COMFORT_V1
import 'package:flutter/foundation.dart' show kIsWeb;

import 'outlook_comfort_storage_stub.dart'
    if (dart.library.js_interop) 'outlook_comfort_storage_web.dart'
    as impl;

const bool faComfortEnabled =
    kIsWeb && bool.fromEnvironment('FA_OUTLOOK_COMFORT');
String? faComfortRead(String key) =>
    faComfortEnabled ? impl.readValue(key) : null;
void faComfortWrite(String key, String? value) {
  if (!faComfortEnabled) return;
  if (!impl.writeValue(key, value)) {
    throw StateError(
      'Browser storage unavailable. Settings were not saved on this device.',
    );
  }
}
