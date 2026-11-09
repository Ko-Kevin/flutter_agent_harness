// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
//
// JavaScript implementation of the typed OfficeApi facade.
// Readiness is established by the Office.onReady callback, rather than
// depending on conversion of its returned JavaScript Promise.

library;

import 'dart:async';
import 'dart:js_interop';

import 'office_api.dart';

@JS('Reflect.get')
external JSAny? _getProperty(JSObject target, JSAny? key);

@JS('Reflect.apply')
external JSAny? _applyFn(
  JSFunction fn,
  JSAny? thisArg,
  JSArray args,
);

@JS('globalThis')
external JSObject get _globalRoot;

const _readyTimeout = Duration(seconds: 60);

JSAny? _prop(JSObject obj, String name) =>
    _getProperty(obj, name.toJS);

JSObject? _obj(JSAny? value) =>
    value.isA<JSObject>() ? value as JSObject : null;

JSFunction? _fn(JSAny? value) =>
    value.isA<JSFunction>() ? value as JSFunction : null;

JSObject? get _officeRoot =>
    _obj(_prop(_globalRoot, 'Office'));

String _s(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int _i(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

/// Convert only a data property, never an entire Office item.
Object? _leaf(JSObject obj, String name) =>
    _prop(obj, name)?.dartify();

/// Invoke an Office callback-style asynchronous method.
Future<Object?> _invokeAsyncResult(
  JSObject target,
  String method,
  List<JSAny?> args,
) {
  final fn = _fn(_prop(target, method));

  if (fn == null) {
    return Future.error(
      OfficeApiException(
        'office_unavailable',
        'Office.js surface $method is not available',
      ),
    );
  }

  final completer = Completer<Object?>();

  void callback(JSAny? result) {
    if (completer.isCompleted) return;

    try {
      final asyncResult = _obj(result);

      if (asyncResult == null) {
        completer.completeError(
          OfficeApiException(
            'office_unavailable',
            '$method returned no valid result',
          ),
        );
        return;
      }

      final status = _s(_leaf(asyncResult, 'status'));

      if (status == 'succeeded') {
        completer.complete(_leaf(asyncResult, 'value'));
        return;
      }

      final error = _obj(_prop(asyncResult, 'error'));
      final message =
          error == null ? '' : _s(_leaf(error, 'message'));

      completer.completeError(
        OfficeApiException(
          'office_unavailable',
          message.isEmpty ? '$method failed' : message,
        ),
      );
    } on Object {
      if (!completer.isCompleted) {
        completer.completeError(
          OfficeApiException(
            'office_unavailable',
            'Could not process the result of $method',
          ),
        );
      }
    }
  }

  try {
    _applyFn(fn, target, [...args, callback.toJS].toJS);
  } on Object {
    if (!completer.isCompleted) {
      completer.completeError(
        OfficeApiException(
          'office_unavailable',
          'Could not invoke Office.js method $method',
        ),
      );
    }
  }

  return completer.future;
}

/// Production Office.js adapter.
///
/// This does not grant permissions or bypass Office initialization.
/// It becomes ready only after Office invokes its readiness callback
/// with a recognized host.
final class JsOfficeApi implements OfficeApi {
  JsOfficeApi() {
    unawaited(
      onReady().catchError((Object error) {
        // Keep startup failures available through _readyFailure.
        // Tool calls will receive a structured OfficeApiException.
      }),
    );
  }

  Future<void>? _readyFuture;
  bool _readyFired = false;
  String? _hostName;
  OfficeApiException? _readyFailure;

  late final _changes =
      StreamController<MailItemSnapshot?>.broadcast(
    onListen: _attachItemChangeHandler,
  );

  bool _handlerAttached = false;

  @override
  bool get isReady => _readyFired;

  @override
  OfficeHostId get host => officeHostFromName(_hostName);

  @override
  Future<void> onReady() {
    if (_readyFired) {
      return Future<void>.value();
    }

    return _readyFuture ??= _doOnReady();
  }

  Future<void> _doOnReady() {
    final completer = Completer<void>();
    Timer? timeout;

    void fail(String message) {
      if (completer.isCompleted) return;

      timeout?.cancel();

      final error = OfficeApiException(
        'office_unavailable',
        message,
      );

      _readyFailure = error;
      completer.completeError(error);
    }

    void readyCallback(JSAny? info) {
      if (completer.isCompleted) return;

      try {
        final details = _obj(info);

        final name = details == null
            ? ''
            : _s(_leaf(details, 'host'));

        if (officeHostFromName(name) == OfficeHostId.other) {
          fail(
            'Office.onReady completed without a recognized '
            'Office host. Open this app inside Outlook.',
          );
          return;
        }

        // Update state directly inside the Office callback.
        // Do not wait for a JavaScript Promise-to-Dart conversion.
        _hostName = name;
        _readyFailure = null;
        _readyFired = true;

        timeout?.cancel();
        completer.complete();

        // A listener might have subscribed before Office was ready.
        if (_changes.hasListener) {
          _attachItemChangeHandler();
        }
      } on Object {
        fail('Could not process the Office readiness callback');
      }
    }

    try {
      final root = _officeRoot;

      if (root == null) {
        fail('Office.js is not available on this page');
        return completer.future;
      }

      final onReadyFunction = _fn(_prop(root, 'onReady'));

      if (onReadyFunction == null) {
        fail('Office.onReady is not available');
        return completer.future;
      }

      timeout = Timer(
        _readyTimeout,
        () => fail(
          'Office.onReady callback did not complete within '
          '${_readyTimeout.inSeconds} seconds',
        ),
      );

      // Official callback form:
      // Office.onReady(function (info) { ... });
      //
      // Reflect.apply preserves Office as the receiver.
      // The returned JS Promise is intentionally not used.
      _applyFn(
        onReadyFunction,
        root,
        <JSAny?>[readyCallback.toJS].toJS,
      );
    } on Object {
      fail('Could not register the Office.onReady callback');
    }

    return completer.future;
  }

  void _requireReady() {
    if (_readyFired) return;

    final failure = _readyFailure;
    if (failure != null) {
      throw failure;
    }

    throw OfficeApiException(
      'not_ready',
      'Office initialization is still in progress. '
      'Wait for Office.onReady before using mail tools.',
    );
  }

  JSObject? get _mailbox {
    final root = _officeRoot;
    if (root == null) return null;

    final context = _obj(_prop(root, 'context'));
    if (context == null) return null;

    return _obj(_prop(context, 'mailbox'));
  }

  JSObject? get _item {
    final mailbox = _mailbox;
    if (mailbox == null) return null;

    return _obj(_prop(mailbox, 'item'));
  }

  /// Compose mode exposes subject as an object with getAsync.
  /// Read mode exposes it as a string.
  bool _isCompose(JSObject item) =>
      _obj(_prop(item, 'subject')) != null;

  @override
  MailItemSnapshot? get currentItem {
    _requireReady();

    final item = _item;
    return item == null ? null : _snapshotOf(item);
  }

  MailItemSnapshot _snapshotOf(JSObject item) {
    final compose = _isCompose(item);

    final fromObj =
        compose ? null : _obj(_prop(item, 'from'));

    final from = fromObj == null
        ? ''
        : _s(
            _leaf(fromObj, 'emailAddress'),
            _s(_leaf(fromObj, 'displayName')),
          );

    return MailItemSnapshot(
      itemId: _s(_leaf(item, 'itemId')),
      mode: compose ? ItemMode.compose : ItemMode.read,
      itemType: _s(_leaf(item, 'itemType')),
      itemClass: _s(_leaf(item, 'itemClass')),
      subject: compose ? '' : _s(_leaf(item, 'subject')),
      from: from,
      to: _recipients(_leaf(item, 'toRecipients')),
      cc: _recipients(_leaf(item, 'ccRecipients')),
      receivedTimeIso: _dateIso(
        _leaf(item, 'dateTimeCreated'),
      ),
      attachments: [
        for (final a in
            ((_leaf(item, 'attachments') as List?) ?? const []))
          if (a is Map)
            AttachmentInfo(
              name: _s(a['name']),
              size: _i(a['size']),
              contentType: _s(a['contentType']),
            ),
      ],
    );
  }

  static List<String> _recipients(Object? raw) => [
    if (raw is List)
      for (final r in raw)
        if (r is Map)
          _s(
            r['emailAddress'],
            _s(r['displayName']),
          ),
  ];

  static String _dateIso(Object? raw) => switch (raw) {
    final DateTime dt => dt.toIso8601String(),
    final String s => s,
    _ => '',
  };

  @override
  Future<String> readItemBodyText() async {
    await onReady();
    _requireReady();

    final item = _item;

    if (item == null) {
      throw OfficeApiException(
        'no_item',
        'no mail item is open',
      );
    }

    final body = _obj(_prop(item, 'body'));

    if (body == null) {
      throw OfficeApiException(
        'no_item',
        'the open item has no body surface',
      );
    }

    return _s(
      await _invokeAsyncResult(
        body,
        'getAsync',
        ['text'.toJS],
      ),
    );
  }

  @override
  Future<AttachmentContent> readAttachment(String name) async {
    await onReady();
    _requireReady();

    final item = _item;

    if (item == null) {
      throw OfficeApiException(
        'no_item',
        'no mail item is open',
      );
    }

    final entries =
        (await _invokeAsyncResult(
          item,
          'getAttachmentsAsync',
          const [],
        )) as List? ??
        const [];

    Map<Object?, Object?>? match;

    for (final entry in entries) {
      if (entry is Map && entry['name'] == name) {
        match = entry;
        break;
      }
    }

    if (match == null) {
      throw OfficeApiException(
        'no_attachment',
        'no attachment named "$name"',
      );
    }

    final size = _i(match['size']);

    if (size > maxAttachmentBytes) {
      throw OfficeApiException(
        'attachment_too_large',
        'attachment "$name" is $size bytes — over the '
            '$maxAttachmentBytes-byte cap; refused',
      );
    }

    final content = await _invokeAsyncResult(
      item,
      'getAttachmentContentAsync',
      [_s(match['id']).toJS],
    );

    final contentMap =
        content is Map ? content : const <Object?, Object?>{};

    final base64 = _s(contentMap['content']);
    final format = _s(contentMap['format']);

    if (format != 'base64' || base64.isEmpty) {
      throw OfficeApiException(
        'office_unavailable',
        'attachment "$name" content unavailable (format: '
            '${format.isEmpty ? 'unknown' : format})',
      );
    }

    return AttachmentContent(
      name: name,
      base64: base64,
      size: size,
    );
  }

  @override
  Future<void> insertDraftBody(String text) async {
    await onReady();
    _requireReady();

    final item = _item;

    if (item == null || !_isCompose(item)) {
      throw OfficeApiException(
        'read_mode',
        'insert_draft_body requires an open compose draft '
            '(current surface is '
            '${item == null ? 'no item' : 'read mode'})',
      );
    }

    final body = _obj(_prop(item, 'body'));

    if (body == null) {
      throw OfficeApiException(
        'read_mode',
        'the open draft has no body',
      );
    }

    await _invokeAsyncResult(
      body,
      'setAsync',
      [
        text.toJS,
        {'coercionType': 'text'}.jsify(),
      ],
    );
  }

  @override
  Stream<MailItemSnapshot?> get onItemChanged =>
      _changes.stream;

  void _attachItemChangeHandler() {
    if (_handlerAttached || !_readyFired) return;

    final mailbox = _mailbox;
    if (mailbox == null) return;

    final addHandler =
        _fn(_prop(mailbox, 'addHandlerAsync'));

    if (addHandler == null) return;

    final root = _officeRoot;
    final eventTypes =
        root == null ? null : _obj(_prop(root, 'EventType'));

    final eventName = eventTypes == null
        ? ''
        : _s(_leaf(eventTypes, 'ItemChanged'));

    if (eventName.isEmpty) return;

    void handler(JSAny? eventArgs) {
      MailItemSnapshot? snapshot;

      try {
        snapshot = currentItem;
      } on Object {
        snapshot = null;
      }

      if (!_changes.isClosed) {
        _changes.add(snapshot);
      }
    }

    void registered(JSAny? result) {
      try {
        final value = _obj(result);

        if (value == null ||
            _s(_leaf(value, 'status')) != 'succeeded') {
          _handlerAttached = false;
        }
      } on Object {
        _handlerAttached = false;
      }
    }

    _handlerAttached = true;

    try {
      _applyFn(
        addHandler,
        mailbox,
        <JSAny?>[
          eventName.toJS,
          handler.toJS,
          registered.toJS,
        ].toJS,
      );
    } on Object {
      _handlerAttached = false;
    }
  }
}

/// Factory exported by the Office package.
OfficeApi? createJsOfficeApi() => JsOfficeApi();
