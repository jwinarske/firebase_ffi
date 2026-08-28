// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

import 'package:firebase_ffi/google_services.dart';
import 'package:test/test.dart';

/// A minimal but realistic file, shaped like the console's output.
String config({
  String? firebaseUrl = 'https://p-default-rtdb.firebaseio.com',
  int clients = 1,
}) {
  final client = '''
    {
      "client_info": {
        "mobilesdk_app_id": "1:1234:android:abcd",
        "android_client_info": {"package_name": "com.example.app"}
      },
      "api_key": [{"current_key": "AIzaTESTKEY"}]
    }''';
  return '''
{
  "project_info": {
    "project_number": "1234",
    ${firebaseUrl == null ? '' : '"firebase_url": "$firebaseUrl",'}
    "project_id": "p",
    "storage_bucket": "p.firebasestorage.app"
  },
  "client": [${List.filled(clients, client).join(',')}],
  "configuration_version": "1"
}''';
}

void main() {
  test('parses the fields initDatabase needs', () {
    final c = GoogleServicesConfig.parse(config());
    expect(c.appId, '1:1234:android:abcd');
    expect(c.apiKey, 'AIzaTESTKEY');
    expect(c.projectId, 'p');
    expect(c.databaseUrl, 'https://p-default-rtdb.firebaseio.com');
    expect(c.storageBucket, 'p.firebasestorage.app');
  });

  test('a missing firebase_url names the cause, not just the field', () {
    // The console omits this until a Realtime Database exists, so the useful
    // message is about the project, not about JSON.
    expect(
      () => GoogleServicesConfig.parse(config(firebaseUrl: null)),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('no Realtime Database'),
        ),
      ),
    );
  });

  test('refuses more than one client rather than guessing', () {
    expect(
      () => GoogleServicesConfig.parse(config(clients: 2)),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('exactly one'),
        ),
      ),
    );
  });

  test('rejects a file with no client entries', () {
    expect(
      () => GoogleServicesConfig.parse('{"project_info":{},"client":[]}'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects JSON that is not an object', () {
    expect(
      () => GoogleServicesConfig.parse('[]'),
      throwsA(isA<FormatException>()),
    );
  });
}
