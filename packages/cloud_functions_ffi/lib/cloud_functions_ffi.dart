// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

/// The `cloud_functions` implementation for desktop Linux.
///
/// Callables route to the C++ SDK. Arguments and results cross as CBOR through
/// the same codec the Realtime Database uses, so a map of scalars, lists and
/// nested maps arrives as itself rather than as JSON text.
///
/// Streaming callables keep the platform interface's own `UnimplementedError`:
/// the desktop SDK has no streaming call to route them to.
library;

import 'dart:async';

import 'package:cloud_functions_platform_interface/cloud_functions_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ffi/functions.dart' as fdb;

/// Registered by Flutter on Linux via `dartPluginClass`.
class CloudFunctionsFfi extends FirebaseFunctionsPlatform {
  CloudFunctionsFfi({FirebaseApp? app, String region = _defaultRegion})
    : super(app, region);

  // What the SDK uses when no region is given, and what cloud_functions
  // defaults to. Named rather than repeated so the two cannot drift.
  static const _defaultRegion = 'us-central1';

  /// Called by the Flutter plugin registrant.
  static void registerWith() {
    FirebaseFunctionsPlatform.instance = CloudFunctionsFfi();
  }

  // One Functions instance per process in the binding, so the region it was
  // created with is the region it keeps. A second instance asking for another
  // region would silently get the first one's, which is worse than saying so.
  static String? _boundRegion;
  static String? _boundOrigin;

  void _ensureFunctions() {
    if (_boundRegion == null) {
      fdb.initFunctions(region: region);
      _boundRegion = region;
      return;
    }
    if (_boundRegion != region) {
      throw UnsupportedError(
        'this build binds one Functions region per process: '
        '$_boundRegion is already in use, so $region cannot also be served',
      );
    }
  }

  // The origin arrives per callable rather than once, because cloud_functions
  // holds it and passes it down. The SDK takes it once, on the instance.
  void _applyOrigin(String? origin) {
    if (origin == null || origin == _boundOrigin) return;
    fdb.useFunctionsEmulator(origin);
    _boundOrigin = origin;
  }

  @override
  FirebaseFunctionsPlatform delegateFor({FirebaseApp? app, String? region}) =>
      CloudFunctionsFfi(app: app, region: region ?? _defaultRegion);

  @override
  HttpsCallablePlatform httpsCallable(
    String? origin,
    String name,
    HttpsCallableOptions options,
  ) => FfiHttpsCallable(this, origin, name, options, null);

  @override
  HttpsCallablePlatform httpsCallableWithUri(
    String? origin,
    Uri uri,
    HttpsCallableOptions options,
  ) {
    // The SDK has GetHttpsCallableFromURL; the binding does not expose it yet.
    // Unimplemented rather than approximated: deriving a name from the URL
    // would call a different function than the one asked for.
    throw UnimplementedError(
      'httpsCallableWithUri is not bound; call by name instead',
    );
  }
}

/// One callable, resolved by name.
class FfiHttpsCallable extends HttpsCallablePlatform {
  FfiHttpsCallable(
    CloudFunctionsFfi super.functions,
    super.origin,
    super.name,
    super.options,
    super.uri,
  );

  CloudFunctionsFfi get _functions => functions as CloudFunctionsFfi;

  @override
  Future<dynamic> call([dynamic parameters]) async {
    _functions._ensureFunctions();
    _functions._applyOrigin(origin);
    try {
      return _fromFfi(await fdb.callFunction(name!, parameters));
    } on fdb.FunctionsException catch (e) {
      // The platform interface's own type, so a caller catching
      // FirebaseFunctionsException catches this the way it does on Android.
      throw FirebaseFunctionsException(
        code: _codeFor(e),
        message: e.message,
        details: null,
      );
    }
  }

  // The SDK reports a numeric error; cloud_functions callers expect the
  // canonical gRPC name. Only the ones the desktop SDK actually produces are
  // mapped -- inventing the rest would claim a precision this does not have.
  static String _codeFor(fdb.FunctionsException e) {
    final message = e.message.toLowerCase();
    if (message.contains('not found')) return 'not-found';
    if (message.contains('unauthenticated')) return 'unauthenticated';
    if (message.contains('permission')) return 'permission-denied';
    return 'unknown';
  }
}

// CBOR decodes a map as Map<Object?, Object?>, and cloud_functions casts a
// result to whatever the caller asked for -- `call<Map<String, dynamic>>()`
// throws on the untyped one. Re-keying is what makes the cast the caller
// writes on Android work here too.
Object? _fromFfi(Object? v) {
  if (v is Map) {
    return v.map((k, e) => MapEntry('$k', _fromFfi(e)));
  }
  if (v is List) return v.map(_fromFfi).toList();
  return v;
}
