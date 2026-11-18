// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The claim this whole layer makes, tested: an app uses firebase_core and
// firebase_auth unchanged, and the calls land on the C++ SDK.
//
// Nothing here mentions firebase_ffi. If these pass, the façade is doing what
// it exists to do; if the API were a lookalike rather than the platform
// interface, this file would not compile.
//
// Skipped without FIREBASE_EMULATOR_HOST, so `flutter test` stays useful.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_ffi/firebase_auth_ffi.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_ffi/firebase_core_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'fdb-emulator';

void main() {
  final host = Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
  if (host.isEmpty) {
    print('FIREBASE_EMULATOR_HOST unset — façade emulator tests skipped');
    return;
  }
  final authPort =
      int.tryParse(Platform.environment['FIREBASE_AUTH_EMULATOR_PORT'] ?? '') ??
      9099;
  final dbPort =
      int.tryParse(
        Platform.environment['FIREBASE_DATABASE_EMULATOR_PORT'] ?? '',
      ) ??
      9000;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // A test binding reports TargetPlatform.android, and FirebaseAuth's
    // useAuthEmulator rewrites 127.0.0.1 to 10.0.2.2 on Android -- the address
    // an Android emulator uses for its host. Pointed at that, the C++ SDK has
    // nothing to reach and the sign-in hangs until the test times out. This
    // implementation is the Linux one, so the test says so.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // Registration is Flutter's job in a real app; a test binding has no
    // plugin registrant, so it is done by hand here.
    FirebaseCoreFfi.registerWith();
    FirebaseAuthFfi.registerWith();

    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: 'emulator-does-not-check-this',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: _projectId,
        databaseURL: 'http://$host:$dbPort/?ns=$_projectId',
      ),
    );
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
  });

  // The desktop SDK persists its session, so a test that did not sign in
  // would inherit whoever the last one left behind — and a restored user's
  // cached token can be old enough to force a refresh the emulator cannot
  // serve. Starting each test signed out makes the suite order-independent.
  setUp(() => FirebaseAuth.instance.signOut());

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('Firebase.app() returns the initialized default app', () {
    expect(Firebase.app().name, defaultFirebaseAppName);
    expect(Firebase.app().options.projectId, _projectId);
  });

  test('signInAnonymously through firebase_auth reaches the SDK', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();
    expect(cred.user, isNotNull);
    expect(cred.user!.uid, isNotEmpty);
    expect(FirebaseAuth.instance.currentUser?.uid, cred.user!.uid);
  });

  test('a password account is created, and signed back into', () async {
    final email = 'a${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'my-secure-password';

    final created = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final uid = created.user!.uid;
    expect(uid, isNotEmpty);
    expect(created.user!.isAnonymous, isFalse);
    expect(created.user!.email, email);
    expect(created.user!.providerData.single.providerId, 'password');
    expect(FirebaseAuth.instance.currentUser?.uid, uid);

    await FirebaseAuth.instance.signOut();
    expect(FirebaseAuth.instance.currentUser, isNull);

    final again = await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    expect(again.user!.uid, uid);
    expect(FirebaseAuth.instance.currentUser?.uid, uid);
    await FirebaseAuth.instance.signOut();

    final byCredential = await FirebaseAuth.instance.signInWithCredential(
      EmailAuthProvider.credential(email: email, password: password),
    );
    expect(byCredential.user!.uid, uid);
    expect(byCredential.user!.isAnonymous, isFalse);
    await FirebaseAuth.instance.signOut();

    await expectLater(
      FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      ),
      throwsA(_authError('email-already-in-use')),
    );
    await expectLater(
      FirebaseAuth.instance.signInWithCredential(
        EmailAuthProvider.credential(email: email, password: 'wrong'),
      ),
      throwsA(_authError('wrong-password')),
    );
  });

  test('an empty email or password is the SDK\'s to refuse', () async {
    await expectLater(
      FirebaseAuth.instance.signInWithEmailAndPassword(email: '', password: ''),
      throwsA(isA<FirebaseAuthException>()),
    );
    await expectLater(
      FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: '',
        password: '',
      ),
      throwsA(isA<FirebaseAuthException>()),
    );
  });

  // The tokens are made up, so each of these is refused. What is under test
  // is that the credential reaches the SDK and the refusal comes back as a
  // FirebaseAuthException, not which code the emulator picks for it.
  test('a federated credential reaches the SDK', () async {
    for (final credential in [
      GoogleAuthProvider.credential(idToken: 'id', accessToken: 'access'),
      GoogleAuthProvider.credential(accessToken: 'access'),
      FacebookAuthProvider.credential('access'),
      GithubAuthProvider.credential('access'),
      TwitterAuthProvider.credential(accessToken: 'access', secret: 'secret'),
      OAuthProvider('apple.com').credential(idToken: 'id', rawNonce: 'nonce'),
      OAuthProvider(
        'microsoft.com',
      ).credential(idToken: 'id', accessToken: 'access'),
      OAuthProvider('yahoo.com').credential(idToken: 'id', rawNonce: 'nonce'),
      OAuthProvider(
        'example.com',
      ).credential(idToken: 'id', accessToken: 'access'),
    ]) {
      await expectLater(
        FirebaseAuth.instance.signInWithCredential(credential),
        throwsA(isA<FirebaseAuthException>()),
        reason: credential.providerId,
      );
    }
  });

  // Each of these would trip an assert in the SDK's GetCredential.
  test('a credential missing what its provider needs is invalid', () async {
    for (final credential in [
      const OAuthCredential(
        providerId: 'twitter.com',
        signInMethod: 'twitter.com',
        accessToken: 'access',
      ),
      const OAuthCredential(
        providerId: 'github.com',
        signInMethod: 'github.com',
        idToken: 'id',
      ),
      OAuthProvider('example.com').credential(accessToken: 'access'),
      // Generic OAuth needs an ID token, and this carries only an access
      // token.
      YahooAuthProvider.credential('access'),
      OAuthProvider('example.com').credential(idToken: 'id'),
    ]) {
      await expectLater(
        FirebaseAuth.instance.signInWithCredential(credential),
        throwsA(_authError('invalid-credential')),
        reason: credential.providerId,
      );
    }
  });

  group('a named app', () {
    late FirebaseApp second;

    setUp(() async {
      second = await Firebase.initializeApp(
        name: 'second',
        options: const FirebaseOptions(
          apiKey: 'emulator-does-not-check-this',
          appId: '1:1:android:1',
          messagingSenderId: '1',
          projectId: _projectId,
        ),
      );
      final auth = FirebaseAuth.instanceFor(app: second);
      await auth.useAuthEmulator(host, authPort);
      // The SDK keeps a session per app name in the secure store, so a run
      // that died signed in comes back signed in. The first event waits for
      // that restore, which makes it the point to sign out from.
      await auth.authStateChanges().first;
      await auth.signOut();
    });

    tearDown(() async {
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instanceFor(app: second).signOut();
      await second.delete();
    });

    test('has its own user', () async {
      final auth = FirebaseAuth.instanceFor(app: second);
      final first = (await FirebaseAuth.instance.signInAnonymously()).user!;
      expect(auth.currentUser, isNull);

      final other = (await auth.signInAnonymously()).user!;
      expect(other.uid, isNot(first.uid));
      expect(auth.currentUser!.uid, other.uid);
      expect(FirebaseAuth.instance.currentUser!.uid, first.uid);

      await auth.signOut();
      expect(auth.currentUser, isNull);
      expect(FirebaseAuth.instance.currentUser!.uid, first.uid);
    });

    test('has its own streams and account management', () async {
      final auth = FirebaseAuth.instanceFor(app: second);
      await FirebaseAuth.instance.signInAnonymously();
      final defaults = <String?>[];
      final seconds = <String?>[];
      final a = FirebaseAuth.instance.userChanges().listen(
        (u) => defaults.add(u?.displayName),
      );
      final b = auth.userChanges().listen((u) => seconds.add(u?.displayName));
      addTearDown(a.cancel);
      addTearDown(b.cancel);

      await auth.signInAnonymously();
      await auth.currentUser!.updateDisplayName('Second App');
      expect(auth.currentUser!.displayName, 'Second App');
      expect(FirebaseAuth.instance.currentUser!.displayName, isNull);
      await _until(() => seconds.contains('Second App'));
      expect(defaults, isNot(contains('Second App')));
    });
  });

  group('account management', () {
    // Not until a test runs: there is no app while the group is declared.
    late final auth = FirebaseAuth.instance;
    // The count as well as the clock: two calls in a row read the same
    // microsecond on Windows, whose clock is coarser than that.
    var made = 0;
    String address() =>
        'f${DateTime.now().microsecondsSinceEpoch}-${made++}@example.com';

    tearDown(() => auth.signOut());

    test('a profile update shows, and userChanges reports it', () async {
      await auth.createUserWithEmailAndPassword(
        email: address(),
        password: 'hunter22',
      );
      final names = <String?>[];
      final sub = auth.userChanges().listen(
        (user) => names.add(user?.displayName),
      );
      addTearDown(sub.cancel);

      await auth.currentUser!.updateDisplayName('Ada Lovelace');
      expect(auth.currentUser!.displayName, 'Ada Lovelace');
      await _until(() => names.contains('Ada Lovelace'));

      await auth.currentUser!.updatePhotoURL('https://example.com/ada.png');
      expect(auth.currentUser!.photoURL, 'https://example.com/ada.png');
      // Setting one field leaves the other alone.
      expect(auth.currentUser!.displayName, 'Ada Lovelace');

      await auth.currentUser!.updateDisplayName(null);
      expect(auth.currentUser!.displayName, isNull);
    });

    test('reload brings in a change made elsewhere', () async {
      await auth.createUserWithEmailAndPassword(
        email: address(),
        password: 'hunter22',
      );
      await _authPost(host, authPort, 'accounts:update', {
        'idToken': await auth.currentUser!.getIdToken(),
        'displayName': 'Changed Elsewhere',
      });
      expect(auth.currentUser!.displayName, isNull);

      await auth.currentUser!.reload();
      expect(auth.currentUser!.displayName, 'Changed Elsewhere');
    });

    test('an anonymous user links a provider and keeps its uid', () async {
      final anonymous = (await auth.signInAnonymously()).user!;
      // The emulator takes a Google ID token that is the claims as JSON.
      final google = GoogleAuthProvider.credential(
        idToken: jsonEncode({
          'sub': 'f${DateTime.now().microsecondsSinceEpoch}',
          'email': address(),
          'email_verified': true,
        }),
      );
      final linked = await anonymous.linkWithCredential(google);
      expect(linked.user!.uid, anonymous.uid);
      expect(linked.user!.isAnonymous, isFalse);
      expect(linked.user!.providerData.single.providerId, 'google.com');

      final unlinked = await auth.currentUser!.unlink('google.com');
      expect(unlinked.uid, anonymous.uid);
      expect(unlinked.providerData, isEmpty);
      await expectLater(
        auth.currentUser!.unlink('google.com'),
        throwsA(_authError('no-such-provider')),
      );
    });

    test('an anonymous user becomes a password account', () async {
      final anonymous = (await auth.signInAnonymously()).user!;
      final email = address();
      final linked = await anonymous.linkWithCredential(
        EmailAuthProvider.credential(email: email, password: 'hunter22'),
      );
      expect(linked.user!.uid, anonymous.uid);
      expect(linked.user!.isAnonymous, isFalse);
      expect(linked.user!.email, email);
      await expectLater(
        auth.currentUser!.linkWithCredential(
          EmailAuthProvider.credential(email: address(), password: 'hunter22'),
        ),
        throwsA(_authError('provider-already-linked')),
      );
    });

    test('a credential that is not bound is not linked either', () async {
      final user = (await auth.signInAnonymously()).user!;
      await expectLater(
        user.linkWithCredential(
          PhoneAuthProvider.credential(verificationId: 'v', smsCode: '000000'),
        ),
        throwsA(isA<UnimplementedError>()),
      );
      await expectLater(
        user.linkWithCredential(
          const OAuthCredential(
            providerId: 'twitter.com',
            signInMethod: 'twitter.com',
            accessToken: 'access',
          ),
        ),
        throwsA(_authError('invalid-credential')),
      );
    });

    test('a password is changed, and the new one reauthenticates', () async {
      final email = address();
      final user = (await auth.createUserWithEmailAndPassword(
        email: email,
        password: 'hunter22',
      )).user!;
      await user.updatePassword('hunter23');

      final proven = await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: 'hunter23'),
      );
      expect(proven.user!.uid, user.uid);
      await expectLater(
        user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: 'hunter22'),
        ),
        throwsA(isA<FirebaseAuthException>()),
      );
    });

    test('the verification and reset mails are sent', () async {
      final email = address();
      final user = (await auth.createUserWithEmailAndPassword(
        email: email,
        password: 'hunter22',
      )).user!;
      await user.sendEmailVerification();
      await user.verifyBeforeUpdateEmail(address());
      await auth.sendPasswordResetEmail(email: email);

      await expectLater(
        auth.sendPasswordResetEmail(email: address()),
        throwsA(_authError('user-not-found')),
      );
      await expectLater(
        user.sendEmailVerification(
          ActionCodeSettings(url: 'https://example.com/done'),
        ),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('delete removes the account and signs out', () async {
      final email = address();
      final user = (await auth.createUserWithEmailAndPassword(
        email: email,
        password: 'hunter22',
      )).user!;
      await user.delete();
      expect(auth.currentUser, isNull);
      await expectLater(
        auth.signInWithEmailAndPassword(email: email, password: 'hunter22'),
        throwsA(_authError('user-not-found')),
      );
    });

    test('a user kept from before a sign-out is refused', () async {
      final user = (await auth.signInAnonymously()).user!;
      await auth.signOut();
      await expectLater(
        user.reload(),
        throwsA(_authError('no-signed-in-user')),
      );
      await expectLater(
        user.updateDisplayName('a'),
        throwsA(_authError('no-signed-in-user')),
      );
    });
  });

  test('an anonymous user is reported as one', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();
    final user = cred.user!;
    expect(user.isAnonymous, isTrue);
    expect(user.email, isNull);
    expect(user.providerData, isEmpty);
    expect(user.metadata.creationTime, isNotNull);
    expect(FirebaseAuth.instance.currentUser!.isAnonymous, isTrue);
  });

  test('a user with an account behind it is not anonymous', () async {
    // The emulator is asked for a password account over REST, and a custom
    // token for its uid signs in as it -- the one way to reach a user with a
    // profile through the sign-ins bound here. The emulator accepts an
    // unsigned token, so no service account is involved.
    final email = 'u${DateTime.now().microsecondsSinceEpoch}@example.com';
    final uid = await _createAccount(host, authPort, email, 'Ada Lovelace');

    final cred = await FirebaseAuth.instance.signInWithCustomToken(
      _unsignedToken(uid),
    );
    final user = cred.user!;
    expect(user.uid, uid);
    expect(user.isAnonymous, isFalse);
    expect(user.email, email);
    expect(user.displayName, 'Ada Lovelace');
    expect(user.emailVerified, isFalse);
    expect(user.photoURL, isNull);
    expect(user.providerData.single.providerId, 'password');
    expect(user.providerData.single.email, email);

    final current = FirebaseAuth.instance.currentUser!;
    expect(current.uid, uid);
    expect(current.email, email);
    expect(current.isAnonymous, isFalse);
  });

  test('a fresh sign-in answers an ID token', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();

    // No refresh happens: the SDK returns the cached token while it has more
    // than five minutes left (GetTokenIfFresh), which it does right after a
    // sign-in. That is why this works against the emulator at all.
    final token = await cred.user!.getIdToken();
    expect(token, isNotNull);
    expect(token!.split('.'), hasLength(3));

    final result = await cred.user!.getIdTokenResult();
    expect(result.token, token);
    expect(result.claims!['user_id'], cred.user!.uid);
    expect(result.signInProvider, 'anonymous');
    expect(result.expirationTime!.isAfter(DateTime.now()), isTrue);
    expect(
      result.issuedAtTime!.isAfter(
        DateTime.now().subtract(const Duration(minutes: 5)),
      ),
      isTrue,
    );
  });

  // The refresh goes through the SDK's SecureTokenRequest, which honors the
  // emulator in 13.13.1 with patch 0010 and leaves it without.
  test('a forced refresh answers a new ID token', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();
    final first = await cred.user!.getIdToken();
    // The emulator stamps a token to the second, so one asked for at once
    // would be the same token again.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final forced = await cred.user!.getIdToken(true);
    expect(forced!.split('.'), hasLength(3));
    expect(forced, isNot(first));
  });

  test('a refused custom token carries the plugin code', () async {
    await expectLater(
      FirebaseAuth.instance.signInWithCustomToken('not.a.token'),
      throwsA(
        isA<FirebaseAuthException>().having(
          (e) => e.code,
          'code',
          'invalid-custom-token',
        ),
      ),
    );
  });

  test('authStateChanges reports the sign-out', () async {
    final seen = <User?>[];
    final sub = FirebaseAuth.instance.authStateChanges().listen(seen.add);
    addTearDown(sub.cancel);

    final cred = await FirebaseAuth.instance.signInAnonymously();
    await FirebaseAuth.instance.signOut();

    // Driven by the SDK's listener: the state when the listener was added,
    // which setUp left signed out, then the sign-in, then the sign-out.
    await _until(() => seen.length >= 3);
    expect(seen.map((u) => u?.uid), [null, cred.user!.uid, null]);
    expect(FirebaseAuth.instance.currentUser, isNull);
  });

  test('a listener added while signed in hears who it is', () async {
    final cred = await FirebaseAuth.instance.signInAnonymously();

    // Nothing passes through the facade between the sign-in and this listen,
    // so the event can only have come from the SDK. A session restored from
    // the secure store reaches an app the same way.
    final first = await FirebaseAuth.instance.authStateChanges().first;
    expect(first?.uid, cred.user!.uid);
    expect(first!.isAnonymous, isTrue);
  });

  test('idTokenChanges and userChanges report a sign-in', () async {
    final tokens = <User?>[];
    final users = <User?>[];
    final a = FirebaseAuth.instance.idTokenChanges().listen(tokens.add);
    final b = FirebaseAuth.instance.userChanges().listen(users.add);
    addTearDown(a.cancel);
    addTearDown(b.cancel);

    final cred = await FirebaseAuth.instance.signInAnonymously();

    // A refresh would add an event to these two and not to authStateChanges.
    // It cannot be shown here: the SDK sends a refresh to the production
    // host, which the test above this one pins down.
    await _until(() => tokens.length >= 2 && users.length >= 2);
    expect(tokens.last?.uid, cred.user!.uid);
    expect(users.last?.uid, cred.user!.uid);
    expect(tokens.first, isNull);
  });
}

/// Waits for [done], which an event from another thread makes true.
Matcher _authError(String code) =>
    isA<FirebaseAuthException>().having((e) => e.code, 'code', code);

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for an auth event');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Posts [body] to one of the Auth emulator's REST methods.
Future<void> _authPost(
  String host,
  int port,
  String method,
  Map<String, Object?> body,
) async {
  // As in _createAccount: the test binding's HttpClient sends nothing.
  final overrides = HttpOverrides.current;
  HttpOverrides.global = null;
  final client = HttpClient();
  HttpOverrides.global = overrides;
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://$host:$port/identitytoolkit.googleapis.com/v1/'
        '$method?key=any',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final answer = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw StateError('$method answered ${response.statusCode}: $answer');
    }
  } finally {
    client.close();
  }
}

/// Creates a password account in the Auth emulator, returning its uid.
Future<String> _createAccount(
  String host,
  int port,
  String email,
  String name,
) async {
  // The test binding replaces HttpClient with one that answers 400 to
  // everything without sending it. This request has to reach the emulator.
  final overrides = HttpOverrides.current;
  HttpOverrides.global = null;
  final client = HttpClient();
  HttpOverrides.global = overrides;
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://$host:$port/identitytoolkit.googleapis.com/v1/'
        'accounts:signUp?key=any',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'email': email,
        'password': 'not-a-secret',
        'displayName': name,
        'returnSecureToken': true,
      }),
    );
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw StateError(
        'accounts:signUp answered ${response.statusCode}: $body',
      );
    }
    return (jsonDecode(body) as Map<String, Object?>)['localId']! as String;
  } finally {
    client.close();
  }
}

/// A custom token with no signature, which only the emulator accepts.
String _unsignedToken(String uid) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'none', 'typ': 'JWT'})}.${part({'aud': 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit', 'iss': 'firebase-auth-emulator@example.com', 'sub': 'firebase-auth-emulator@example.com', 'iat': now, 'exp': now + 3600, 'uid': uid})}.';
}
