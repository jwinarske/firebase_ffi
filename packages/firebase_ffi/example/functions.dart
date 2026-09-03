// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The Cloud Functions binding, end to end.
//
//   dart run example/functions.dart
//
// Calling a callable by name, what its arguments and results are allowed to
// be, and how a function that throws arrives here.
//
// The callables used are the three the emulator fixtures define, in
// test/emulator/functions/index.js:
//
//   echo(data) -> {received: data}
//   add({a, b}) -> a + b
//   boom() -> throws
//
// Against a real project, deploy equivalents or set FDB_CALLABLE to one of
// your own — the program says which name it is calling.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ffi/functions.dart';

import 'setup.dart';

Future<void> main() async {
  await start(use: {Product.functions});

  await _arguments();
  await _results();
  await _failures();
  _regions();
}

Future<void> _arguments() async {
  step('arguments: what can be sent');

  // The argument is encoded as CBOR and handed to the SDK as a Variant, so a
  // callable receives the shape that was sent rather than a JSON string.
  final echoed =
      await callFunction('echo', {
            'text': 'hello',
            'n': 42,
            // A double, written in the narrowest float that holds it.
            // Reading that width back wrongly once turned 1.5 into 0.0,
            // which is why it is here.
            'ratio': 1.5,
            'flag': true,
            'nothing': null,
            'list': [1, 'two', null],
            'nested': {'deep': true},
          })
          as Map;

  final received = echoed['received'] as Map;
  for (final e in received.entries) {
    final type = e.value.runtimeType.toString().padRight(16);
    note('${'${e.key}'.padRight(8)} $type ${e.value}');
  }

  // A callable takes no argument at all just as happily.
  note('with no argument: ${await callFunction('echo')}');
}

Future<void> _results() async {
  step('results: what can come back');

  // Not every callable answers a map. A bare number is a valid result and
  // arrives as one rather than as a single-entry envelope.
  final sum = await callFunction('add', {'a': 20, 'b': 22});
  note('add(20, 22) = $sum  (${sum.runtimeType})');

  final name = Platform.environment['FDB_CALLABLE'];
  if (name != null) {
    note('FDB_CALLABLE set: calling $name');
    note('$name -> ${await callFunction(name)}');
  }

  // Bytes are the exception, and the failure is worth seeing: a callable's
  // payload is JSON over HTTPS, which has no byte type, and the C++ SDK
  // refuses a Variant carrying a blob rather than encoding it behind your
  // back. Encode them yourself, and decode on the other side.
  try {
    final blob = await callFunction('echo', {
      'bytes': Uint8List.fromList([1, 2, 250]),
    });
    note('a blob was accepted: $blob');
  } on Object catch (e) {
    note('a blob is refused: $e');
    final encoded = base64Encode([1, 2, 250]);
    final back = await callFunction('echo', {'bytes': encoded}) as Map;
    note(
      'base64 goes through: ${(back['received'] as Map)['bytes']} '
      '-> ${base64Decode(encoded)}',
    );
  }
}

Future<void> _failures() async {
  step('failures');

  // A function that throws surfaces as FunctionsException carrying the SDK's
  // own code and the message the function chose — not as a null result an app
  // has to guess about.
  try {
    await callFunction('boom');
    note('boom() unexpectedly succeeded');
  } on FunctionsException catch (e) {
    note('FunctionsException(${e.name}) code ${e.code}: ${e.message}');
  }

  // A name nothing is deployed under is the same kind of failure, which is
  // worth knowing: it is reported, not silently ignored.
  try {
    await callFunction('not_deployed_${DateTime.now().microsecondsSinceEpoch}');
    note('an undeployed name unexpectedly succeeded');
  } on FunctionsException catch (e) {
    note('an undeployed name: code ${e.code} — ${e.message}');
  }
}

void _regions() {
  step('regions');

  // A callable is addressed by region, and the default is us-central1. A
  // function deployed elsewhere is unreachable until the binding is
  // initialized for that region:
  //
  //   initFunctions(region: 'europe-west1');
  //
  // useFunctionsEmulator() overrides the origin instead, which is what
  // setup.dart does when FIREBASE_EMULATOR_HOST is set.
  note(
    'initFunctions(region: ...) selects the region; the default is '
    'us-central1',
  );
}
