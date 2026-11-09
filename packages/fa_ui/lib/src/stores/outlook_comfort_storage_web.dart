import 'dart:js_interop';

// Private browser storage, not the agent sandbox filesystem.
// Local storage is NOT an encrypted credential vault.
@JS('window.localStorage.getItem')
external JSString? _read(JSString key);
@JS('window.localStorage.setItem')
external void _write(JSString key, JSString value);
@JS('window.localStorage.removeItem')
external void _remove(JSString key);
String _slot(String key) => 'faFixed.comfort.v1:' + key;
String? readValue(String key) {
  try {
    return _read(_slot(key).toJS)?.toDart;
  } on Object {
    return null;
  }
}

bool writeValue(String key, String? value) {
  try {
    if (value == null) {
      _remove(_slot(key).toJS);
    } else {
      _write(_slot(key).toJS, value.toJS);
    }
    return _read(_slot(key).toJS)?.toDart == value;
  } on Object {
    return false;
  }
}
