// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Exercises the bindings against the Firebase emulator suite.
//
// Everything else in CI builds and links; nothing calls the SDK. That gap is
// not theoretical: Storage crashed on two runs in three from a use-after-free
// in a completion callback, and no amount of building would have found it —
// only calling it does.
//
// Run by scripts/run_emulator_tests.sh, which starts the emulators. Skipped
// when FIREBASE_EMULATOR_HOST is unset, so `dart test` stays useful without
// them.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ffi/auth.dart';
import 'package:firebase_ffi/database.dart';
import 'package:firebase_ffi/firestore.dart';
import 'package:firebase_ffi/functions.dart';
import 'package:firebase_ffi/remote_config.dart';
import 'package:firebase_ffi/storage.dart';
import 'package:test/test.dart';

const _projectId = 'fdb-emulator';

String get _host => Platform.environment['FIREBASE_EMULATOR_HOST'] ?? '';
int _port(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

// Big enough that an upload to an emulator on this machine is still going when
// the test reaches in to pause or cancel it.
const _bigUpload = 64 * 1024 * 1024;

void main() {
  if (_host.isEmpty) {
    // Not a failure: the suite is meaningless without a backend, and saying so
    // is better than a green run that tested nothing.
    print('FIREBASE_EMULATOR_HOST unset — emulator tests skipped');
    return;
  }

  final dbPort = _port('FIREBASE_DATABASE_EMULATOR_PORT', 9000);
  final authPort = _port('FIREBASE_AUTH_EMULATOR_PORT', 9099);
  final fnPort =
      int.tryParse(
        Platform.environment['FIREBASE_FUNCTIONS_EMULATOR_PORT'] ?? '',
      ) ??
      5001;
  final fsPort = _port('FIREBASE_FIRESTORE_EMULATOR_PORT', 8080);
  final stPort = _port('FIREBASE_STORAGE_EMULATOR_PORT', 9199);

  setUpAll(() {
    // The database URL is the emulator's, which is all Database needs: the
    // url argument overrides whatever the app options carry.
    initDatabase(
      appId: '1:1:android:1',
      apiKey: 'emulator-does-not-check-this',
      projectId: _projectId,
      databaseUrl: 'http://$_host:$dbPort/?ns=$_projectId',
      // Storage has no url argument to override this with: the bucket comes
      // from the app options, and an empty one builds a URL with no bucket in
      // it, which the emulator answers slowly and unhelpfully rather than
      // rejecting.
      storageBucket: '$_projectId.appspot.com',
    );
    initAuth();
    useAuthEmulator(_host, authPort);
    // Only what this build bound. The suite is run against several product
    // selections, and initializing a product that was not compiled in fails
    // at symbol resolution rather than saying so.
    if (hasFirestore) {
      initFirestore();
      useFirestoreEmulator(_host, fsPort);
    }
    if (hasStorage) {
      initStorage();
      useStorageEmulator(_host, stPort);
    }
  });

  test('a named app is created beside the default one, and deleted', () {
    void create() => initNamedApp(
      name: 'secondary',
      appId: '1:1:android:1',
      apiKey: 'emulator-does-not-check-this',
      projectId: 'a-second-project',
    );

    create();
    // The name is taken until the app is deleted.
    expect(create, throwsStateError);
    deleteNamedApp('secondary');
    expect(() => deleteNamedApp('secondary'), throwsStateError);
    // And free again afterwards.
    create();
    deleteNamedApp('secondary');

    expect(
      () => initNamedApp(name: '', appId: 'a', apiKey: 'k', projectId: 'p'),
      throwsArgumentError,
    );
  });

  test('auth signs in anonymously against the emulator', () async {
    final who = await signInAnonymously();
    expect(who.uid, isNotEmpty);
    expect(currentUid(), who.uid);
  });

  test('an anonymous user is reported as one', () async {
    final who = await signInAnonymously();
    expect(who.user.uid, who.uid);
    expect(who.user.isAnonymous, isTrue);
    expect(who.user.email, isNull);
    expect(who.user.providerData, isEmpty);
    expect(who.user.creationTime, isNotNull);

    final current = currentUser();
    expect(current, isNotNull);
    expect(current!.uid, who.uid);
    expect(current.isAnonymous, isTrue);
  });

  test('a user with an account behind it carries the profile', () async {
    // Neither sign-in bound here creates a password account, so the emulator
    // is asked for one over REST, and a custom token for its uid signs in as
    // it. The emulator accepts an unsigned token, which is what lets a test
    // mint one with no service account.
    final email = 'u${DateTime.now().microsecondsSinceEpoch}@example.com';
    final uid = await _createAccount(authPort, email, 'Ada Lovelace');

    final who = await signInWithCustomToken(_unsignedToken(uid));
    expect(who.uid, uid);
    expect(who.user.isAnonymous, isFalse);
    expect(who.user.email, email);
    expect(who.user.displayName, 'Ada Lovelace');
    expect(who.user.isEmailVerified, isFalse);
    expect(who.user.photoUrl, isNull);

    final provider = who.user.providerData.single;
    expect(provider.providerId, 'password');
    expect(provider.email, email);

    final current = currentUser()!;
    expect(current.uid, uid);
    expect(current.email, email);
    expect(current.providerData.single.providerId, 'password');
  });

  test('nobody signed in is no current user', () {
    signOut();
    expect(currentUser(), isNull);
  });

  test('a password account is created and signed into', () async {
    final email = 'b${DateTime.now().microsecondsSinceEpoch}@example.com';
    final created = await createUserWithEmailAndPassword(email, 'hunter22');
    expect(created.user.email, email);
    expect(created.user.isAnonymous, isFalse);
    expect(currentUid(), created.uid);
    signOut();

    final who = await signInWithCredential({
      'providerId': 'password',
      'email': email,
      'secret': 'hunter22',
      // firebase_auth sends the fields it has no value for as null, and keys
      // the binding does not read.
      'emailLink': null,
      'token': null,
    });
    expect(who.uid, created.uid);
    expect(who.user.providerData.single.providerId, 'password');
    signOut();
  });

  test('a credential its provider cannot be built from is refused', () async {
    // 4 is kAuthErrorInvalidCredential. Twitter with no secret would trip an
    // assert in the SDK if it got that far.
    for (final credential in <Map<String, Object?>>[
      {'providerId': 'twitter.com', 'accessToken': 'a', 'secret': null},
      {'providerId': 'password', 'email': 'a@example.com'},
      {'providerId': 'example.com', 'accessToken': 'a'},
    ]) {
      await expectLater(
        signInWithCredential(credential),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 4)),
        reason: '${credential['providerId']}',
      );
    }
    // Refused before anything is sent: the SDK would cut the string there.
    expect(
      () => signInWithCredential({
        'providerId': 'password',
        'email': 'a@example.com',
        'secret': 'abc\u0000def',
      }),
      throwsArgumentError,
    );
    expect(
      () => createUserWithEmailAndPassword('a@example.com', 'abc\u0000def'),
      throwsArgumentError,
    );
    // No provider id is not a credential at all.
    await expectLater(
      signInWithCredential({'accessToken': 'a'}),
      throwsStateError,
    );
  });

  group('auth on a named app', () {
    const second = 'second';

    // The SDK keeps a session per app name in the secure store, so a run that
    // died signed in comes back signed in. The first auth-state event is held
    // until that restore has finished, which makes it the point to sign out
    // from.
    Future<void> start() async {
      initNamedApp(
        name: second,
        appId: '1:1:android:1',
        apiKey: 'emulator-does-not-check-this',
        projectId: _projectId,
      );
      initAuth(app: second);
      useAuthEmulator(_host, authPort, app: second);
      await authStateChanges(app: second).first;
      signOut(app: second);
    }

    setUp(start);

    tearDown(() {
      signOut();
      signOut(app: second);
      try {
        deleteNamedApp(second);
      } on StateError {
        // The test deleted it.
      }
    });

    test('it has its own user', () async {
      final first = await signInAnonymously();
      expect(currentUid(app: second), isNull);

      final other = await signInAnonymously(app: second);
      expect(other.uid, isNot(first.uid));
      expect(currentUid(app: second), other.uid);
      expect(currentUid(), first.uid);
      expect(currentUser(app: second)!.isAnonymous, isTrue);

      // Signing out of one leaves the other signed in.
      signOut(app: second);
      expect(currentUid(app: second), isNull);
      expect(currentUid(), first.uid);
    });

    test('it has its own streams', () async {
      final defaults = <String?>[];
      final seconds = <String?>[];
      final a = authStateChanges().listen((u) => defaults.add(u?.uid));
      final b = authStateChanges(
        app: second,
      ).listen((u) => seconds.add(u?.uid));
      addTearDown(a.cancel);
      addTearDown(b.cancel);
      await _eventually(() => defaults.isNotEmpty && seconds.isNotEmpty);
      expect(seconds, [null]);

      final who = await signInAnonymously(app: second);
      await _eventually(() => seconds.length == 2);
      expect(seconds, [null, who.uid]);
      // The default app heard none of it.
      expect(defaults, hasLength(1));
    });

    test('account management acts on its user', () async {
      await signInAnonymously();
      final email = 'n${DateTime.now().microsecondsSinceEpoch}@example.com';
      final made = await createUserWithEmailAndPassword(
        email,
        'hunter22',
        app: second,
      );
      await updateProfile(displayName: 'Second App', app: second);
      expect(currentUser(app: second)!.displayName, 'Second App');
      expect(currentUser()!.displayName, isNull);
      expect((await idToken(app: second)).split('.'), hasLength(3));

      await deleteUser(app: second);
      expect(currentUid(app: second), isNull);
      expect(currentUid(), isNot(made.uid));
      expect(currentUid(), isNotNull);
    });

    test('deleting the app ends its streams and its Auth', () async {
      await signInAnonymously(app: second);
      var done = false;
      authStateChanges(app: second).listen((_) {}, onDone: () => done = true);

      deleteNamedApp(second);
      await _eventually(() => done);
      expect(currentUid(app: second), isNull);
      await expectLater(signInAnonymously(app: second), throwsStateError);
      expect(() => initAuth(app: second), throwsStateError);

      // The name can be used again.
      await start();
      final again = await signInAnonymously(app: second);
      expect(currentUid(app: second), again.uid);
    });

    test('an app that does not exist is not initialized', () {
      expect(() => initAuth(app: 'nobody'), throwsStateError);
      expect(currentUid(app: 'nobody'), isNull);
    });
  });

  group('account management', () {
    // The count as well as the clock: two calls in a row read the same
    // microsecond on Windows, whose clock is coarser than that.
    var made = 0;
    String address() =>
        'm${DateTime.now().microsecondsSinceEpoch}-${made++}@example.com';
    Matcher failsWith(int code) =>
        throwsA(isA<AuthException>().having((e) => e.code, 'code', code));

    tearDown(signOut);

    test('a profile update shows in the current user', () async {
      await createUserWithEmailAndPassword(address(), 'hunter22');
      await updateProfile(
        displayName: 'Ada Lovelace',
        photoUrl: 'https://example.com/ada.png',
      );
      expect(currentUser()!.displayName, 'Ada Lovelace');
      expect(currentUser()!.photoUrl, 'https://example.com/ada.png');

      // Empty removes a field, and one left out is left alone.
      await updateProfile(displayName: '');
      expect(currentUser()!.displayName, isNull);
      expect(currentUser()!.photoUrl, 'https://example.com/ada.png');
    });

    test('reload brings in a change made elsewhere', () async {
      await createUserWithEmailAndPassword(address(), 'hunter22');
      await _authPost(authPort, 'accounts:update', {
        'idToken': await idToken(),
        'displayName': 'Changed Elsewhere',
      });
      expect(currentUser()!.displayName, isNull);

      await reloadUser();
      expect(currentUser()!.displayName, 'Changed Elsewhere');
    });

    test('an anonymous user keeps its uid on linking a provider', () async {
      final anonymous = await signInAnonymously();
      final email = address();
      // The emulator takes a Google ID token that is the claims as JSON.
      final google = {
        'providerId': 'google.com',
        'idToken': jsonEncode({
          'sub': 'g${DateTime.now().microsecondsSinceEpoch}',
          'email': email,
          'email_verified': true,
        }),
      };
      final linked = await linkWithCredential(google);
      expect(linked.uid, anonymous.uid);
      expect(linked.user.isAnonymous, isFalse);
      expect(linked.user.email, email);
      expect(linked.user.providerData.single.providerId, 'google.com');
      expect(currentUser()!.providerData.single.providerId, 'google.com');

      // The account signs in by what was linked.
      signOut();
      final again = await signInWithCredential(google);
      expect(again.uid, anonymous.uid);

      final unlinked = await unlinkProvider('google.com');
      expect(unlinked.uid, anonymous.uid);
      expect(unlinked.user.providerData, isEmpty);
      // 16 is kAuthErrorNoSuchProvider.
      await expectLater(unlinkProvider('google.com'), failsWith(16));
    });

    // Needs the SDK's SignUpRequest to honor the emulator, which 13.13.1
    // does with patch 0010 and not without it.
    test('an anonymous user becomes a password account', () async {
      final anonymous = await signInAnonymously();
      final email = address();
      final linked = await linkWithCredential({
        'providerId': 'password',
        'email': email,
        'secret': 'hunter22',
      });
      expect(linked.uid, anonymous.uid);
      expect(linked.user.isAnonymous, isFalse);
      expect(linked.user.email, email);
      expect(linked.user.providerData.single.providerId, 'password');

      signOut();
      final again = await signInWithCredential({
        'providerId': 'password',
        'email': email,
        'secret': 'hunter22',
      });
      expect(again.uid, anonymous.uid);
      // 15 is kAuthErrorProviderAlreadyLinked.
      await expectLater(
        linkWithCredential({
          'providerId': 'password',
          'email': address(),
          'secret': 'hunter22',
        }),
        failsWith(15),
      );
    });

    test('a linked credential is checked like a sign-in one', () async {
      await signInAnonymously();
      // 4 is kAuthErrorInvalidCredential.
      await expectLater(
        linkWithCredential({'providerId': 'twitter.com', 'accessToken': 'a'}),
        failsWith(4),
      );
      await expectLater(
        linkWithCredential({'accessToken': 'a'}),
        throwsStateError,
      );
    });

    test('a password is changed, and the new one reauthenticates', () async {
      final email = address();
      final created = await createUserWithEmailAndPassword(email, 'hunter22');
      await updatePassword('hunter23');

      final proven = await reauthenticateWithCredential({
        'providerId': 'password',
        'email': email,
        'secret': 'hunter23',
      });
      expect(proven.uid, created.uid);
      await expectLater(
        reauthenticateWithCredential({
          'providerId': 'password',
          'email': email,
          'secret': 'hunter22',
        }),
        throwsA(isA<AuthException>()),
      );
      expect(() => updatePassword('abc\u0000def'), throwsArgumentError);
    });

    test('the three mails are asked of the server', () async {
      final email = address();
      final moved = address();
      await createUserWithEmailAndPassword(email, 'hunter22');
      await sendEmailVerification();
      await verifyBeforeUpdateEmail(moved);
      await sendPasswordResetEmail(email);

      // The emulator sends nothing, and keeps what it would have sent.
      final codes = await _oobCodes(authPort);
      Iterable<Object?> kinds(String to) => codes
          .where((code) => code['email'] == to || code['newEmail'] == to)
          .map((code) => code['requestType']);
      expect(kinds(email), containsAll(['VERIFY_EMAIL', 'PASSWORD_RESET']));
      expect(kinds(moved), contains('VERIFY_AND_CHANGE_EMAIL'));

      // 14 is kAuthErrorUserNotFound.
      await expectLater(sendPasswordResetEmail(address()), failsWith(14));
    });

    test('delete removes the account and signs out', () async {
      final email = address();
      await createUserWithEmailAndPassword(email, 'hunter22');
      await deleteUser();
      expect(currentUid(), isNull);
      await expectLater(
        signInWithCredential({
          'providerId': 'password',
          'email': email,
          'secret': 'hunter22',
        }),
        failsWith(14),
      );
    });

    test('with nobody signed in each call says so', () async {
      signOut();
      // 24 is kAuthErrorNoSignedInUser.
      await expectLater(reloadUser(), failsWith(24));
      await expectLater(deleteUser(), failsWith(24));
      await expectLater(sendEmailVerification(), failsWith(24));
      await expectLater(updatePassword('hunter22'), failsWith(24));
      await expectLater(updateProfile(displayName: 'a'), failsWith(24));
      await expectLater(unlinkProvider('password'), failsWith(24));
      await expectLater(
        linkWithCredential({
          'providerId': 'password',
          'email': 'a@example.com',
          'secret': 'hunter22',
        }),
        failsWith(24),
      );
    });
  });

  test('authStateChanges follows the SDK', () async {
    signOut();
    final seen = <String?>[];
    final sub = authStateChanges().listen((user) => seen.add(user?.uid));
    addTearDown(sub.cancel);

    // The state when the listener was added comes first, unasked.
    await _eventually(() => seen.isNotEmpty);
    expect(seen, [null]);

    final who = await signInAnonymously();
    await _eventually(() => seen.length >= 2);
    signOut();
    await _eventually(() => seen.length >= 3);
    expect(seen, [null, who.uid, null]);
  });

  test('a second auth listener is told the current state', () async {
    final who = await signInAnonymously();
    final first = authStateChanges().listen((_) {});
    addTearDown(first.cancel);

    // The native side has one port, so this one joins a subscription that has
    // already had its first event. It is replayed rather than missed.
    final user = await authStateChanges().first;
    expect(user?.uid, who.uid);
  });

  test('idTokenChanges reports a sign-in and a sign-out', () async {
    signOut();
    final seen = <String?>[];
    final sub = idTokenChanges().listen((user) => seen.add(user?.uid));
    addTearDown(sub.cancel);

    final who = await signInAnonymously();
    await _eventually(() => seen.contains(who.uid));
    signOut();
    await _eventually(() => seen.last == null && seen.length >= 3);
    expect(seen.first, isNull);
  });

  test('a cancelled auth listener can be listened to again', () async {
    final who = await signInAnonymously();
    expect((await authStateChanges().first)?.uid, who.uid);
    // `first` cancelled, which closed the native port. A new listener opens
    // another and gets the state again.
    expect((await authStateChanges().first)?.uid, who.uid);
  });

  group('database values', () {
    setUpAll(() async => signInAnonymously());

    String probe() => '/probe/${DateTime.now().microsecondsSinceEpoch}';

    // Reads go through a listener rather than a one-shot get. The desktop
    // SDK's GetValue is a single-shot listener that completes on the first
    // event, and for a path with nothing cached that event is the empty local
    // state -- it answers null for data that is on the server. A listener
    // receives the server's value on its second event, which is what this
    // waits for.
    Future<Object?> readBack(String path) async {
      final completer = Completer<Object?>();
      late StreamSubscription<DbSnapshot> sub;
      sub = onValue(path).listen((s) {
        if (s.value != null && !completer.isCompleted)
          completer.complete(s.value);
      });
      try {
        return await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        await sub.cancel();
      }
    }

    test('a map round trips with its types intact', () async {
      final path = probe();
      await setValue(path, {
        'text': 'hello',
        'n': 42,
        'ratio': 1.5,
        'flag': true,
        'nested': {'deep': 'yes'},
        'list': [1, 2, 3],
      });

      final back = (await readBack(path))! as Map;
      expect(back['text'], 'hello');
      expect(back['n'], 42);
      expect(back['ratio'], closeTo(1.5, 1e-9));
      expect(back['flag'], true);
      expect((back['nested'] as Map)['deep'], 'yes');
      expect(back['list'], [1, 2, 3]);
    });

    test('update writes named children and leaves the rest', () async {
      final path = probe();
      await setValue(path, {'keep': 'me', 'change': 'before'});
      await updateChildren(path, {'change': 'after'});

      final back = (await readBack(path))! as Map;
      // The distinction the call exists for: set with a partial map would have
      // deleted 'keep'.
      expect(back['keep'], 'me');
      expect(back['change'], 'after');
    });

    test('remove deletes what was there', () async {
      final path = probe();
      await setValue(path, 'here');
      expect(await readBack(path), 'here');

      await removeValue(path);
      final seen = <Object?>[];
      final sub = onValue(path).listen((s) => seen.add(s.value));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      expect(seen.last, isNull);
    });

    test('push generates a distinct key without a request', () async {
      final path = probe();
      final a = pushChild(path);
      final b = pushChild(path);
      expect(a, isNotEmpty);
      expect(a, isNot(b));

      await setValue('$path/$a', 'first');
      final back = (await readBack(path))! as Map;
      expect(back[a], 'first');
    });
  });

  group('database reads', () {
    setUpAll(() async => signInAnonymously());

    test('a written value reads back', () async {
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, {'a': 1, 'b': 'two'});

      final back = (await readValue(path))! as Map;
      expect(back['a'], 1);
      expect(back['b'], 'two');
    });

    test('a path that was never written reads as null', () async {
      // The case the SDK's own GetValue gets right by accident and gets wrong
      // for everything else: here it has to be null because it is empty, not
      // because the read gave up.
      expect(await readValue('/probe/never-written-at-all'), isNull);
    });

    test('a second read of a cached path still returns the value', () async {
      // A cached path delivers one event, not two. Counting events would read
      // null here while the value was sitting in front of it.
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'cached');

      expect(await readValue(path), 'cached');
      expect(await readValue(path), 'cached');
    });

    test('a read can be filtered by the server', () async {
      final root = '/probe/rq${DateTime.now().microsecondsSinceEpoch}';
      await setValue(root, {
        'ana': {'score': 30},
        'bo': {'score': 10},
        'cy': {'score': 20},
      });

      final low = await readValue(
        root,
        query: const DbQuery().orderByChild('score').limitToFirst(1),
      );
      final high = await readValue(
        root,
        query: const DbQuery().orderByChild('score').limitToLast(1),
      );

      // Filtered at the server: reading the whole node and narrowing here
      // would give the same answer to both, and would fetch three children to
      // return one.
      expect((low! as Map).keys.single, 'bo');
      expect((high! as Map).keys.single, 'ana');
    });

    test('a read with a query the ABI cannot apply is an error', () async {
      await expectLater(
        readValue(
          '/probe/rq-bad',
          query: const DbQuery().orderByKey().limitToFirst(1).limitToLast(1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a removed value reads as null again', () async {
      final path = '/probe/rd${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'here');
      expect(await readValue(path), 'here');

      await removeValue(path);
      expect(await readValue(path), isNull);
    });
  });

  group('database queries', () {
    setUpAll(() async => signInAnonymously());

    // A node of scores, written once and queried several ways.
    late String root;
    setUpAll(() async {
      root = '/probe/q${DateTime.now().microsecondsSinceEpoch}';
      await setValue(root, {
        'ana': {'score': 30},
        'bo': {'score': 10},
        'cy': {'score': 20},
      });
    });

    Future<Object?> firstValue(Stream<DbSnapshot> s) async {
      final completer = Completer<Object?>();
      late StreamSubscription<DbSnapshot> sub;
      sub = s.listen((e) {
        if (e.value != null && !completer.isCompleted)
          completer.complete(e.value);
      });
      try {
        return await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        await sub.cancel();
      }
    }

    test('a limit returns fewer children than the node holds', () async {
      final v = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToFirst(2),
        ),
      );
      expect((v! as Map).length, 2);
    });

    test('an ordered limit takes from the right end', () async {
      final low = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToFirst(1),
        ),
      );
      final high = await firstValue(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').limitToLast(1),
        ),
      );
      // Ordering by score: bo is 10, ana is 30. If the ordering were dropped
      // the two would come back the same, which is the failure a weaker query
      // produces and does not report.
      expect((low! as Map).keys.single, 'bo');
      expect((high! as Map).keys.single, 'ana');
    });

    test('a bound excludes what falls outside it', () async {
      final v = await firstValue(
        onQueryValue(root, const DbQuery().orderByChild('score').startAt(20)),
      );
      final keys = (v! as Map).keys.toSet();
      expect(keys, containsAll(<String>['cy', 'ana']));
      expect(keys, isNot(contains('bo')));
    });

    test('a spec this ABI cannot apply is refused, not weakened', () async {
      // Both limits at once: the SDK keeps whichever was applied last rather
      // than reporting the conflict, so it is refused here. Running it would
      // return a different set than was asked for and say nothing.
      await expectLater(
        onQueryValue(
          root,
          const DbQuery().orderByKey().limitToFirst(1).limitToLast(1),
        ).first,
        throwsA(isA<ArgumentError>()),
      );
    });

    test('equalTo with a bound is refused', () async {
      await expectLater(
        onQueryValue(
          root,
          const DbQuery().orderByChild('score').equalTo(10).startAt(5),
        ).first,
        throwsA(isA<ArgumentError>()),
      );
    });

    test('child events name the child and the one before it', () async {
      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(
        root,
        const DbQuery().orderByChild('score'),
      ).listen(events.add);
      await _until(
        () => events.length >= 3,
        'the three existing children to arrive',
      );
      await sub.cancel();

      expect(events.every((e) => e.event == DbChildEvent.added), isTrue);
      // In score order: bo 10, cy 20, ana 30. The first has no predecessor,
      // and each later one names the child before it -- which is what lets a
      // caller keep an ordered list without re-reading the node.
      expect(events.map((e) => e.key).toList(), ['bo', 'cy', 'ana']);
      expect(events.first.previousKey, isNull);
      expect(events[1].previousKey, 'bo');
      expect(events[2].previousKey, 'cy');
    });

    test('a removal arrives as its own event', () async {
      final path = '/probe/r${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, {'gone': 'soon'});

      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(path).listen(events.add);
      await _until(() => events.isNotEmpty, 'the child to be seen');

      await removeValue('$path/gone');
      await _until(
        () => events.any((e) => e.event == DbChildEvent.removed),
        'the removal',
      );
      await sub.cancel();

      // A value listener cannot report this: once the node is gone it reports
      // null and says nothing about which child left.
      final removed = events.firstWhere((e) => e.event == DbChildEvent.removed);
      expect(removed.key, 'gone');
    });
  });

  group('database transactions', () {
    setUpAll(() async => signInAnonymously());

    test('a counter increments from its current value', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 7);

      final seen = <Object?>[];
      final committed = await runDbTransaction(path, (current) {
        seen.add(current);
        // The first attempt often sees null: the SDK runs the handler against
        // local state before the server's value arrives, then runs it again.
        final n = (current as int?) ?? 0;
        return DbTransactionResult.commit(n + 1);
      });

      expect(committed, 8);
      // Whatever the attempts saw, the last one had to see the real value or
      // the commit could not be 8.
      expect(seen, isNotEmpty);
    });

    test('a handler may run more than once and must not accumulate', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 1);

      var calls = 0;
      final committed = await runDbTransaction(path, (current) {
        calls++;
        // Derived from `current` alone, never from a running total. A handler
        // that accumulated would give a different answer per retry count.
        return DbTransactionResult.commit(((current as int?) ?? 0) * 10);
      });

      expect(committed, 10);
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('aborting leaves the value alone', () async {
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'untouched');

      final result = await runDbTransaction(
        path,
        (_) => const DbTransactionResult.abort(),
      );
      expect(result, isNull);

      final seen = <Object?>[];
      final sub = onValue(path).listen((s) => seen.add(s.value));
      await _until(
        () => seen.any((v) => v == 'untouched'),
        'the untouched value',
      );
      await sub.cancel();
    });

    test('a handler that throws aborts rather than hanging', () async {
      // The SDK's thread is parked until the handler answers, so a throw that
      // did not answer would leave the transaction outstanding forever.
      final path = '/probe/tx${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'safe');

      final result = await runDbTransaction(path, (_) {
        throw StateError('handler blew up');
      }).timeout(const Duration(seconds: 15));
      expect(result, isNull);
    });
  });

  group('database priorities and sync', () {
    setUpAll(() async => signInAnonymously());

    String probe() => '/probe/pr${DateTime.now().microsecondsSinceEpoch}';

    Future<Object?> settled(String path) async {
      Object? last;
      final sub = onValue(path).listen((s) => last = s.value);
      await Future<void>.delayed(const Duration(seconds: 2));
      await sub.cancel();
      return last;
    }

    test('a priority orders siblings', () async {
      final root = probe();
      // Written out of order on purpose: insertion order is not the ordering
      // under test, the priority is.
      await setValueWithPriority('$root/second', {'x': 1}, 20);
      await setValueWithPriority('$root/first', {'x': 1}, 10);
      await setValueWithPriority('$root/third', {'x': 1}, 30);

      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(
        root,
        const DbQuery().orderByPriority(),
      ).listen(events.add);
      await _until(() => events.length >= 3, 'the three children');
      await sub.cancel();

      expect(events.map((e) => e.key).toList(), ['first', 'second', 'third']);
    });

    test('setting a priority reorders without touching the value', () async {
      final root = probe();
      await setValueWithPriority('$root/a', 'value-a', 10);
      await setValueWithPriority('$root/b', 'value-b', 20);

      // a was first; move it behind b.
      await setPriority('$root/a', 30);

      final events = <DbChildSnapshot>[];
      final sub = onChildEvent(
        root,
        const DbQuery().orderByPriority(),
      ).listen(events.add);
      await _until(() => events.length >= 2, 'both children');
      await sub.cancel();

      expect(events.map((e) => e.key).toList(), ['b', 'a']);
      // The value is untouched: setPriority is not a write of the node.
      expect(await settled('$root/a'), 'value-a');
    });

    test('keepSynced is accepted with and without a query', () async {
      final root = probe();
      await setValue(root, {'a': 1});
      // The SDK has no getter for it, so this asserts what can be asserted:
      // it is taken rather than refused, for a plain path and a filtered one.
      expect(() => keepSynced(root, true), returnsNormally);
      expect(
        () => keepSynced(root, true, const DbQuery().orderByKey()),
        returnsNormally,
      );
      expect(() => keepSynced(root, false), returnsNormally);
    });

    test('a query keepSynced cannot apply is refused', () async {
      expect(
        () => keepSynced(
          probe(),
          true,
          const DbQuery().orderByKey().limitToFirst(1).limitToLast(1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('purging outstanding writes is accepted', () async {
      // Nothing is outstanding here -- the emulator is local and writes land
      // immediately. What this pins is that the call reaches the SDK and
      // returns, not that a pending write was dropped.
      expect(purgeOutstandingWrites, returnsNormally);
    });

    test('onDisconnect can carry a priority', () async {
      final path = probe();
      await expectLater(
        OnDisconnect(path).setValueWithPriority('gone', 5),
        completes,
      );
      await OnDisconnect(path).cancel();
    });
  });

  group('database onDisconnect', () {
    setUpAll(() async => signInAnonymously());

    // The value a listener has settled on, rather than a particular event.
    //
    // Counting events does not work here: the desktop SDK sends local state
    // first and the server's answer second, but only when the two differ, so
    // a test that skipped the first and waited for a second timed out on a
    // slower machine and read null for a value that was there. Taking the
    // last value in a window is true whether one event arrives or three.
    Future<Object?> settledValue(
      String path, {
      Duration window = const Duration(seconds: 3),
    }) async {
      Object? last;
      final sub = onValue(path).listen((s) => last = s.value);
      await Future<void>.delayed(window);
      await sub.cancel();
      return last;
    }

    // Waits for the value to become what is expected, so the common case is
    // fast and a slow one still passes.
    Future<Object?> valueBecomes(String path, Object? expected) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Object? seen;
      while (DateTime.now().isBefore(deadline)) {
        seen = await settledValue(
          path,
          window: const Duration(milliseconds: 750),
        );
        if (seen == expected) return seen;
      }
      return seen;
    }

    test('a registration completes', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await expectLater(OnDisconnect(path).setValue('gone'), completes);
      await OnDisconnect(path).cancel();
    });

    test('the server runs it when the connection drops', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'present');
      expect(await valueBecomes(path, 'present'), 'present');

      // The point of the whole feature: this is the cleanup that happens when
      // a device loses power, where nothing on the device gets to run.
      await OnDisconnect(path).remove();
      goOffline();
      goOnline();

      expect(
        await valueBecomes(path, null),
        isNull,
        reason: 'the server never ran the handler',
      );
    });

    test('a canceled registration does not run', () async {
      final path = '/probe/od${DateTime.now().microsecondsSinceEpoch}';
      await setValue(path, 'stays');
      expect(await valueBecomes(path, 'stays'), 'stays');

      await OnDisconnect(path).remove();
      await OnDisconnect(path).cancel();
      goOffline();
      goOnline();

      // Settled over a window rather than checked immediately: an instant
      // check would pass even if cancel did nothing, because the server would
      // not have run the handler yet.
      expect(
        await settledValue(path, window: const Duration(seconds: 5)),
        'stays',
      );
    });
  });

  group('storage', skip: hasStorage ? null : 'Storage not bound', () {
    // The rules require an authenticated caller, so a binding that loses the
    // credential fails here rather than passing against an open emulator.
    setUpAll(() async => signInAnonymously());

    String probe() => 'probe/${DateTime.now().microsecondsSinceEpoch}';

    test('an object round trips its bytes', () async {
      final path = probe();
      final payload = Uint8List.fromList(List.generate(2048, (i) => i & 0xff));

      final meta = await putObject(
        path,
        payload,
        contentType: 'application/x-test',
      );
      expect(meta.sizeBytes, payload.length);
      expect(meta.contentType, 'application/x-test');

      final back = await getObject(path);
      expect(back, payload);
    });

    test('an empty object is not an error', () async {
      // Zero-length is the case a length-prefixed transport gets wrong, and it
      // is indistinguishable from a failed read unless it is checked.
      final path = probe();
      await putObject(path, Uint8List(0));
      expect(await getObject(path), isEmpty);
    });

    test('metadata comes back for an object that exists', () async {
      final path = probe();
      await putObject(
        path,
        Uint8List.fromList([1, 2, 3]),
        contentType: 'text/plain',
      );

      final meta = await objectMetadata(path);
      expect(meta.sizeBytes, 3);
      expect(meta.contentType, 'text/plain');
      expect(meta.path, contains('probe/'));
    });

    test('a deleted object is gone', () async {
      final path = probe();
      await putObject(path, Uint8List.fromList([7]));
      await deleteObject(path);

      await expectLater(getObject(path), throwsA(isA<StorageException>()));
    });

    test('reading an object that was never written fails', () async {
      await expectLater(
        getObject('probe/never-written'),
        throwsA(isA<StorageException>()),
      );
    });

    test('a large object survives the round trip', () async {
      // Past the point where the transfer is a single buffer, which is where
      // the use-after-free in a completion callback lived.
      final path = probe();
      final payload = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => (i * 31) & 0xff),
      );
      await putObject(path, payload);
      expect(await getObject(path), payload);
    });

    test('a file is uploaded from disk', () async {
      final dir = Directory.systemTemp.createTempSync('fdb-put-file');
      addTearDown(() => dir.deleteSync(recursive: true));
      final payload = Uint8List.fromList(
        List.generate(300 * 1024, (i) => (i * 7) & 0xff),
      );
      final file = File('${dir.path}/payload.bin')..writeAsBytesSync(payload);

      final path = probe();
      final meta = await putFile(path, file.path, contentType: 'image/x-test');
      expect(meta.sizeBytes, payload.length);
      expect(meta.contentType, 'image/x-test');
      expect(await getObject(path), payload);
    });

    test('a file that is not there fails the upload', () async {
      await expectLater(
        putFile(probe(), '${Directory.systemTemp.path}/fdb-no-such-file'),
        throwsA(isA<StorageException>()),
      );
    });

    test('a listing separates objects from prefixes', () async {
      final root = 'list/${DateTime.now().microsecondsSinceEpoch}';
      final one = Uint8List.fromList([1]);
      await putObject('$root/a.txt', one);
      await putObject('$root/b.txt', one);
      await putObject('$root/sub/c.txt', one);
      await putObject('$root/sub/deeper/d.txt', one);

      final top = await listObjects(root);
      expect(top.items, unorderedEquals(['$root/a.txt', '$root/b.txt']));
      expect(top.prefixes, ['$root/sub']);
      expect(top.nextPageToken, isNull);

      // A listed path is one the other calls take as it is.
      expect(await getObject(top.items.first), one);

      final sub = await listObjects(top.prefixes.single);
      expect(sub.items, ['$root/sub/c.txt']);
      expect(sub.prefixes, ['$root/sub/deeper']);
    });

    test('a listing is paged', () async {
      final root = 'list/${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 5; i++) {
        await putObject('$root/$i', Uint8List.fromList([i]));
      }

      final seen = <String>[];
      String? token;
      var pages = 0;
      do {
        final page = await listObjects(root, maxResults: 2, pageToken: token);
        expect(page.items.length, lessThanOrEqualTo(2));
        seen.addAll(page.items);
        token = page.nextPageToken;
        pages++;
      } while (token != null);

      expect(pages, 3);
      expect(seen, [for (var i = 0; i < 5; i++) '$root/$i']);
    });

    test('listing where there is nothing is empty, not an error', () async {
      final empty = await listObjects('list/nothing-was-ever-put-here');
      expect(empty.items, isEmpty);
      expect(empty.prefixes, isEmpty);
      expect(empty.nextPageToken, isNull);
    });

    test('an upload carries the metadata it was given', () async {
      final path = probe();
      final meta = await putObject(
        path,
        Uint8List.fromList([1, 2, 3]),
        metadata: const SettableStorageMetadata(
          contentType: 'text/x-test',
          cacheControl: 'max-age=60',
          contentLanguage: 'en',
          custom: {'owner': 'ada'},
        ),
      );
      expect(meta.contentType, 'text/x-test');

      final stored = await objectMetadata(path);
      expect(stored.cacheControl, 'max-age=60');
      expect(stored.contentLanguage, 'en');
      expect(stored.custom, {'owner': 'ada'});
    });

    test('metadata is updated, and what was not named stays', () async {
      final path = probe();
      await putObject(
        path,
        Uint8List.fromList([1, 2, 3]),
        metadata: const SettableStorageMetadata(
          contentType: 'text/x-test',
          custom: {'owner': 'ada'},
        ),
      );

      final updated = await updateObjectMetadata(
        path,
        const SettableStorageMetadata(
          cacheControl: 'no-store',
          custom: {'reviewed': 'yes'},
        ),
      );
      expect(updated.cacheControl, 'no-store');
      expect(updated.contentType, 'text/x-test');
      expect(updated.sizeBytes, 3);

      final stored = await objectMetadata(path);
      expect(stored.cacheControl, 'no-store');
      expect(stored.custom['reviewed'], 'yes');
    });

    test('updating the metadata of nothing fails', () async {
      await expectLater(
        updateObjectMetadata(
          'probe/never-written',
          const SettableStorageMetadata(cacheControl: 'no-store'),
        ),
        throwsA(isA<StorageException>()),
      );
    });

    test('an object is downloaded to a file', () async {
      final dir = Directory.systemTemp.createTempSync('fdb-get-file');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = probe();
      final payload = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 13) & 0xff),
      );
      await putObject(path, payload);

      final file = File('${dir.path}/download.bin');
      final task = startFileDownload(path, file.path);
      final seen = <TransferProgress>[];
      final sub = task.progress.listen(seen.add);
      final written = await task.done;
      await sub.asFuture<void>();

      expect(written, payload.length);
      expect(file.readAsBytesSync(), payload);
      // The last report is not promised to be the whole object: the SDK
      // reports as the body arrives, and the result is what says it is done.
      expect(seen, isNotEmpty);
      expect(seen.last.bytesTransferred, lessThanOrEqualTo(payload.length));
      expect(seen.last.bytesTransferred, greaterThan(0));
    });

    test('downloading what was never written fails', () async {
      final dir = Directory.systemTemp.createTempSync('fdb-get-file');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        getFile('probe/never-written', '${dir.path}/nothing.bin'),
        throwsA(isA<StorageException>()),
      );
    });

    test('an upload reports its progress', () async {
      final payload = Uint8List(4 * 1024 * 1024);
      final task = startUpload(probe(), payload);
      final seen = <TransferProgress>[];
      final sub = task.progress.listen(seen.add);

      final meta = await task.done;
      await sub.asFuture<void>();
      expect(meta.sizeBytes, payload.length);
      expect(seen, isNotEmpty);
      expect(seen.last.bytesTransferred, payload.length);
      expect(seen.last.totalBytes, payload.length);
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i].bytesTransferred,
          greaterThanOrEqualTo(seen[i - 1].bytesTransferred),
        );
      }
      // Finished, so there is nothing left to act on.
      expect(task.pause(), isFalse);
      expect(task.cancel(), isFalse);
    });

    test('an upload is paused, resumed and finishes', () async {
      final path = probe();
      final payload = Uint8List(_bigUpload);
      final task = startUpload(path, payload);
      final seen = <TransferProgress>[];
      final started = Completer<void>();
      final paused = Completer<TransferProgress>();
      final sub = task.progress.listen((p) {
        seen.add(p);
        if (!started.isCompleted) started.complete();
        if (p.paused && !paused.isCompleted) paused.complete(p);
      });

      await started.future;
      expect(task.pause(), isTrue);
      // The report the pause itself produces.
      expect((await paused.future).bytesTransferred, lessThan(payload.length));

      // Nothing moves while it is paused. A chunk already on its way when the
      // pause landed may still report, so let that settle first.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = seen.last.bytesTransferred;
      expect(before, lessThan(payload.length));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(seen.last.bytesTransferred, before);

      expect(task.resume(), isTrue);
      final meta = await task.done;
      await sub.cancel();
      expect(meta.sizeBytes, payload.length);
      expect(seen.last.bytesTransferred, payload.length);
    });

    test('a cancelled upload fails as cancelled', () async {
      final path = probe();
      final task = startUpload(path, Uint8List(_bigUpload));
      // The failure is expected; without a listener it is an unhandled error
      // in the gap before it is awaited.
      final failed = expectLater(
        task.done,
        throwsA(
          isA<StorageException>().having((e) => e.cancelled, 'cancelled', true),
        ),
      );

      await task.progress.first;
      expect(task.cancel(), isTrue);
      await failed;
      await expectLater(objectMetadata(path), throwsA(isA<StorageException>()));
    });
  });

  group(
    'storage on a named app',
    skip: hasStorage ? null : 'Storage not bound',
    () {
      const second = 'second-storage';
      const bucket = 'a-second-bucket.appspot.com';

      // Its own Auth too: the rules want a caller who is signed in, and the
      // credential Storage sends is the one its own app holds.
      Future<void> start() async {
        initNamedApp(
          name: second,
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
          storageBucket: bucket,
        );
        initAuth(app: second);
        useAuthEmulator(_host, authPort, app: second);
        await authStateChanges(app: second).first;
        initStorage(app: second);
        useStorageEmulator(_host, stPort, app: second);
        await signInAnonymously(app: second);
      }

      setUp(() async {
        await signInAnonymously();
        await start();
      });

      tearDown(() {
        try {
          signOut(app: second);
          deleteNamedApp(second);
        } on StateError {
          // The test deleted it.
        }
      });

      String probe() => 'probe/${DateTime.now().microsecondsSinceEpoch}';

      test('it has its own bucket', () async {
        final path = probe();
        final payload = Uint8List.fromList(List.generate(64, (i) => i));

        final meta = await putObject(path, payload, app: second);
        expect(meta.bucket, bucket);
        expect(await getObject(path, app: second), payload);
        expect((await listObjects('probe', app: second)).items, contains(path));

        // The default app's bucket has nothing there.
        await expectLater(
          objectMetadata(path),
          throwsA(isA<StorageException>()),
        );

        await deleteObject(path, app: second);
        await expectLater(
          objectMetadata(path, app: second),
          throwsA(isA<StorageException>()),
        );
      });

      test('it needs its own init', () {
        initNamedApp(
          name: 'no-storage',
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
          storageBucket: bucket,
        );
        addTearDown(() => deleteNamedApp('no-storage'));

        expect(
          () => startUpload(probe(), Uint8List(1), app: 'no-storage'),
          throwsStateError,
        );
        expect(() => initStorage(app: 'nobody'), throwsStateError);
      });

      test('deleting the app cancels an upload on it', () async {
        final path = probe();
        final task = startUpload(path, Uint8List(_bigUpload), app: second);
        final failed = expectLater(
          task.done,
          throwsA(
            isA<StorageException>().having(
              (e) => e.cancelled,
              'cancelled',
              true,
            ),
          ),
        );

        await task.progress.first;
        deleteNamedApp(second);
        await failed;

        // Nothing is left to start on.
        expect(
          () => startUpload(path, Uint8List(1), app: second),
          throwsStateError,
        );
        // The default app's Storage is untouched.
        final other = probe();
        await putObject(other, Uint8List(3));
        expect(await getObject(other), hasLength(3));
      });

      test(
        'deleting the app right after an upload starts cancels it',
        () async {
          // A transfer has nothing to cancel it by until its first report. One
          // that has not made it yet is caught during the wait.
          final task = startUpload(probe(), Uint8List(_bigUpload), app: second);
          final failed = expectLater(
            task.done,
            throwsA(
              isA<StorageException>().having(
                (e) => e.cancelled,
                'cancelled',
                true,
              ),
            ),
          );

          deleteNamedApp(second);
          await failed;
        },
      );

      test('it sends its own app\'s credential', () async {
        // The default app is signed in and this one is not. The rules want a
        // caller who is, so a request carrying the default app's token would
        // get through.
        signOut(app: second);
        expect(currentUid(), isNotNull);

        await expectLater(
          putObject(probe(), Uint8List(4), app: second),
          throwsA(isA<StorageException>()),
        );
      });

      test('an app made again under the name starts clean', () async {
        final path = probe();
        await putObject(path, Uint8List(8), app: second);
        signOut(app: second);
        deleteNamedApp(second);

        await start();
        expect(await getObject(path, app: second), hasLength(8));
      });
    },
  );

  test('an ID token comes back for the signed-in user', () async {
    // The SDK's own guidance: do not authenticate a backend with the uid, use
    // the token. It is the only thing here that lets an app call a service of
    // its own with the identity it already has.
    await signInAnonymously();
    final token = await idToken();
    expect(token, isNotEmpty);
    // Three dot-separated parts. A non-JWT would still be a non-empty string.
    expect(token.split('.').length, 3);
  });

  test('an ID token needs somebody signed in', () async {
    signOut();
    await expectLater(idToken(), throwsA(isA<StateError>()));
    await signInAnonymously();
  });

  test('database round trips a value', () async {
    final path = '/probe/${DateTime.now().microsecondsSinceEpoch}';
    final seen = <String>[];
    final sub = onValue(path).listen((s) {
      if (s.value != null) seen.add('${s.value}');
    });
    addTearDown(sub.cancel);

    setString(path, 'hello');
    await _until(() => seen.contains('hello'), 'the written value to arrive');
  });

  test(
    'firestore round trips a document, tags intact',
    skip: hasFirestore ? null : 'Firestore not bound',
    () async {
      final path = 'probe/${DateTime.now().microsecondsSinceEpoch}';
      final when = FirestoreTimestamp.fromDateTime(
        DateTime.utc(
          2026,
          8,
          30,
          12,
          0,
          0,
          0,
        ).add(const Duration(microseconds: 1)),
      );
      await setDocument(path, {
        'text': 'hello',
        'count': 42,
        'bytes': Uint8List.fromList([1, 2, 250]),
        'when': when,
        'where': const FirestoreGeoPoint(51.5074, -0.1278),
        'nested': {'deep': true},
      });

      final back = await getDocument(path);
      expect(back, isNotNull);
      expect(back!['text'], 'hello');
      expect(back['count'], 42);
      expect(back['bytes'], isA<Uint8List>());
      expect((back['bytes']! as Uint8List).toList(), [1, 2, 250]);
      expect(back['where'], isA<FirestoreGeoPoint>());
      expect((back['nested']! as Map)['deep'], true);

      // The tag that cannot survive a float64 epoch, which is why timestamps do
      // not travel as RFC 8949 tag 1.
      final t = back['when']! as FirestoreTimestamp;
      expect(t.nanoseconds, when.nanoseconds);

      await deleteDocument(path);
      expect(await getDocument(path), isNull);
    },
  );

  group('queries', skip: hasFirestore ? null : 'Firestore not bound', () {
    // One collection per run: the emulator keeps state for the process, and a
    // filter matching leftovers from an earlier run would pass for the wrong
    // reason.
    final coll = 'probe_q_${DateTime.now().microsecondsSinceEpoch}';

    setUpAll(() async {
      for (var i = 0; i < 5; i++) {
        await setDocument('$coll/doc$i', {
          'n': i,
          'even': i.isEven,
          'tag': i < 3 ? 'low' : 'high',
        });
      }
    });

    test('reads a whole collection', () async {
      final docs = await queryCollection(coll);
      expect(docs, hasLength(5));
      expect(docs.map((d) => d.id).toSet(), {
        'doc0',
        'doc1',
        'doc2',
        'doc3',
        'doc4',
      });
      // The id and path are why documents come back rather than bodies:
      // without them a result cannot be addressed again.
      expect(docs.first.path, startsWith('$coll/'));
    });

    test('filters with where', () async {
      final low = await queryCollection(
        coll,
        where: const [Where.equalTo('tag', 'low')],
      );
      expect(low.map((d) => d.id).toSet(), {'doc0', 'doc1', 'doc2'});

      final big = await queryCollection(
        coll,
        where: const [Where.greaterThanOrEqualTo('n', 3)],
      );
      expect(big.map((d) => d.id).toSet(), {'doc3', 'doc4'});
    });

    test('orders and limits', () async {
      final desc = await queryCollection(
        coll,
        orderBy: const [OrderBy('n', descending: true)],
        limit: 2,
      );
      expect(desc.map((d) => d.data['n']).toList(), [4, 3]);
    });

    test('combines a filter with an ordering', () async {
      final evens = await queryCollection(
        coll,
        where: const [Where.equalTo('even', true)],
        orderBy: const [OrderBy('n')],
      );
      expect(evens.map((d) => d.data['n']).toList(), [0, 2, 4]);
    });

    test('a query matching nothing is empty, not an error', () async {
      final none = await queryCollection(
        coll,
        where: const [Where.equalTo('tag', 'nonexistent')],
      );
      expect(none, isEmpty);
    });

    test('a field path the SDK rejects does not abort the process', () async {
      // The SDK validates field paths and throws std::invalid_argument. That
      // exception crossing the ABI would kill the process rather than reach
      // Dart, so it is caught and returned as an error code -- and the proof
      // is that the test after this one still runs.
      await expectLater(
        queryCollection(coll, where: const [Where.equalTo('bad/path', 1)]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the isolate survived the rejected field path', () async {
      final docs = await queryCollection(coll);
      expect(docs, hasLength(5));
    });

    test('a watched query reports a document that starts matching', () async {
      final seen = <List<QueryDocument>>[];
      final sub = onQuery(
        coll,
        where: const [Where.equalTo('tag', 'watched')],
      ).listen(seen.add);
      addTearDown(sub.cancel);

      // The first emission is the current state: nothing matches yet.
      await _until(() => seen.isNotEmpty, 'the initial result');
      expect(seen.first, isEmpty);

      await setDocument('$coll/watched1', {'n': 99, 'tag': 'watched'});
      await _until(
        () => seen.any((r) => r.length == 1),
        'the new document to arrive',
      );
      expect(seen.last.single.id, 'watched1');

      // And stops matching when it no longer does.
      await setDocument('$coll/watched1', {'n': 99, 'tag': 'other'});
      await _until(() => seen.last.isEmpty, 'the document to leave the result');

      // Removed rather than left behind: this collection is shared with the
      // other tests in the group, and a stray document changes what they see.
      // It did — the cursor test counted this one as a fourth row.
      await deleteDocument('$coll/watched1');
    });

    test('cursors page through an ordered result', () async {
      const order = [OrderBy('n')];

      final firstPage = await queryCollection(coll, orderBy: order, limit: 2);
      expect(firstPage.map((d) => d.data['n']).toList(), [0, 1]);

      // startAfter takes the last value of the page before it — which is why
      // the ordering has to be carried along with the cursor.
      final secondPage = await queryCollection(
        coll,
        orderBy: order,
        limit: 2,
        startAfter: [firstPage.last.data['n']],
      );
      expect(secondPage.map((d) => d.data['n']).toList(), [2, 3]);

      // Inclusive and exclusive bounds differ by exactly the boundary row.
      final fromTwo = await queryCollection(coll, orderBy: order, startAt: [2]);
      expect(fromTwo.map((d) => d.data['n']).toList(), [2, 3, 4]);

      final upToTwo = await queryCollection(
        coll,
        orderBy: order,
        endBefore: [2],
      );
      expect(upToTwo.map((d) => d.data['n']).toList(), [0, 1]);
    });

    test('a cursor without an ordering is refused, not ignored', () async {
      // Firestore requires one cursor value per orderBy clause. Without an
      // ordering there is nothing for the value to mean, and running the query
      // anyway would return the whole collection as though the cursor applied.
      await expectLater(
        queryCollection(coll, startAt: [2]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an operator the ABI does not know is refused', () async {
      // Refused rather than dropped: a filter silently ignored would return
      // every document and look like data.
      await expectLater(
        queryCollection(coll, where: const [Where('n', 'approximately', 3)]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group(
    'remote config',
    skip: hasRemoteConfig ? null : 'Remote Config not bound',
    () {
      // Defaults are client-side, so this needs no backend — which is the only
      // reason Remote Config can be tested here at all. The emulator suite has
      // no Remote Config, and a fetch needs a real project.
      setUpAll(() async => initRemoteConfig());

      test('defaults come back with their types intact', () async {
        await setConfigDefaults({
          'greeting': 'hello',
          'retries': 3,
          'ratio': 1.5,
          'enabled': true,
        });

        final values = await configValues();
        expect(values['greeting'], 'hello');
        expect(values['retries'], 3);
        expect(values['ratio'], closeTo(1.5, 1e-9));
        expect(values['enabled'], true);
        // The point of reading a map rather than typed getters: a string does
        // not silently become 0 because something asked for a long.
        expect(values['greeting'], isA<String>());
        expect(values['retries'], isA<int>());
      });

      test('a key with no default is absent, not empty', () async {
        final values = await configValues();
        expect(values.containsKey('never-set'), isFalse);
      });
    },
  );

  group(
    'remote config settings and info',
    skip: hasRemoteConfig ? null : 'Remote Config not bound',
    () {
      setUpAll(() async => initRemoteConfig());

      test('settings round trip', () async {
        await setConfigSettings(
          const RemoteConfigSettings(
            fetchTimeout: Duration(seconds: 17),
            minimumFetchInterval: Duration(minutes: 3),
          ),
        );
        final s = configSettings();
        expect(s.fetchTimeout, const Duration(seconds: 17));
        expect(s.minimumFetchInterval, const Duration(minutes: 3));
      });

      test('nothing fetched yet is not reported as a successful fetch', () {
        // The SDK reports success with a zero fetch time before anything has
        // been fetched. Passing that through as success would tell a caller a
        // fetch worked when none happened.
        final info = configInfo();
        expect(info.lastFetchStatus, RemoteConfigFetchStatus.noFetchYet);
        expect(info.lastFetchTime.millisecondsSinceEpoch, 0);
      });

      test('a default reports itself as a default, not as fetched', () async {
        // The SDK orders ValueSource static, remote, default; the Dart enum
        // orders it static, default, remote. Reading it through the index
        // would report every default as a fetched value -- which is exactly
        // the question this getter exists to answer.
        await setConfigDefaults({'origin_probe': 'local'});
        expect(
          configValueSource('origin_probe'),
          RemoteConfigValueSource.defaultValue,
        );
        expect(
          configValueSource('never_set_anywhere'),
          RemoteConfigValueSource.static,
        );
      });

      test(
        'activating with nothing fetched answers false, not an error',
        () async {
          // There is no Remote Config emulator, so a fetch cannot be exercised
          // here. Activate can: with nothing fetched it must report that there
          // was nothing new rather than fail.
          expect(await activateConfig(), isFalse);
        },
      );
    },
  );

  group('functions', skip: hasFunctions ? null : 'Functions not bound', () {
    setUpAll(() {
      initFunctions();
      // The SDK takes a whole origin here, not a host and port.
      useFunctionsEmulator('http://$_host:$fnPort');
    });

    test('a callable round trips its argument', () async {
      final result = await callFunction('echo', {
        'text': 'hello',
        'n': 42,
        // A double, because the encoder picks the narrowest float that holds
        // the value and the decoder has to read that width back. 1.5 fits in a
        // half, and reading it as a double gave 0.0.
        'ratio': 1.5,
        'nested': {'deep': true},
        'list': [1, 2, 3],
      });
      final received = (result! as Map)['received']! as Map;
      expect(received['text'], 'hello');
      expect(received['n'], 42);
      expect(received['ratio'], closeTo(1.5, 1e-9));
      expect((received['nested']! as Map)['deep'], true);
      expect(received['list'], [1, 2, 3]);
    });

    test('a numeric result comes back as a number', () async {
      expect(await callFunction('add', {'a': 2, 'b': 3}), 5);
    });

    test('a callable that throws carries its reason', () async {
      await expectLater(
        callFunction('boom'),
        throwsA(
          isA<FunctionsException>().having(
            (e) => e.message,
            'message',
            contains('deliberate failure'),
          ),
        ),
      );
    });

    test('a callable is reached by its URL', () async {
      // The emulator's address for it, which is what the SDK builds from the
      // name. Given whole, it is used as given.
      final url = 'http://$_host:$fnPort/fdb-emulator/us-central1/add';
      expect(await callFunctionAtUrl(url, {'a': 20, 'b': 22}), 42);
    });

    test('a second region is its own instance', () async {
      const eu = CallOptions(region: 'europe-west1');
      initFunctions(region: 'europe-west1');
      useFunctionsEmulator('http://$_host:$fnPort', region: 'europe-west1');

      // `where` is deployed to europe-west1 only.
      expect(await callFunction('where', null, eu), 'europe-west1');
      await expectLater(
        callFunction('where'),
        throwsA(isA<FunctionsException>()),
      );
      // And the first region still answers.
      expect(await callFunction('add', {'a': 2, 'b': 3}), 5);
    });

    test('a region that was never initialized is refused', () async {
      await expectLater(
        callFunction('add', null, const CallOptions(region: 'asia-east1')),
        throwsStateError,
      );
      expect(
        () => useFunctionsEmulator('http://$_host:1', region: 'asia-east1'),
        throwsStateError,
      );
    });
  });

  group(
    'functions on a named app',
    skip: hasFunctions ? null : 'Functions not bound',
    () {
      const second = 'second-functions';
      const onSecond = CallOptions(app: second);

      // Its own Auth too, so a callable can say whose call it was.
      Future<void> start() async {
        initNamedApp(
          name: second,
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
        );
        initAuth(app: second);
        useAuthEmulator(_host, authPort, app: second);
        await authStateChanges(app: second).first;
        signOut(app: second);
        initFunctions(app: second);
        useFunctionsEmulator('http://$_host:$fnPort', app: second);
      }

      setUpAll(() {
        initFunctions();
        useFunctionsEmulator('http://$_host:$fnPort');
      });

      setUp(start);

      // The default app's user is left signed in: the groups after this one
      // need it.
      tearDown(() {
        try {
          signOut(app: second);
          deleteNamedApp(second);
        } on StateError {
          // The test deleted it.
        }
      });

      test('it calls as its own user', () async {
        final first = await signInAnonymously();
        // Nobody is signed in on the second app, and the default app's user
        // does not stand in.
        expect(await callFunction('whoami', null, onSecond), isNull);
        expect(await callFunction('whoami'), first.uid);

        final other = await signInAnonymously(app: second);
        expect(other.uid, isNot(first.uid));
        expect(await callFunction('whoami', null, onSecond), other.uid);
        expect(await callFunction('whoami'), first.uid);
      });

      test('it has its own regions', () async {
        // The default app may have europe-west1 from another test. This app
        // has only the region it was given.
        await expectLater(
          callFunction(
            'where',
            null,
            const CallOptions(region: 'europe-west1', app: second),
          ),
          throwsStateError,
        );

        initFunctions(region: 'europe-west1', app: second);
        useFunctionsEmulator(
          'http://$_host:$fnPort',
          region: 'europe-west1',
          app: second,
        );
        expect(
          await callFunction(
            'where',
            null,
            const CallOptions(region: 'europe-west1', app: second),
          ),
          'europe-west1',
        );
      });

      test('it needs its own init', () async {
        initNamedApp(
          name: 'no-functions',
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
        );
        addTearDown(() => deleteNamedApp('no-functions'));

        await expectLater(
          callFunction('add', null, const CallOptions(app: 'no-functions')),
          throwsStateError,
        );
        expect(() => initFunctions(app: 'nobody'), throwsStateError);
      });

      test('deleting the app waits for a call on it', () async {
        final call = callFunction('slow', {'ms': 500}, onSecond);
        deleteNamedApp(second);
        // It was let finish, so it is answered.
        expect(await call, 'done');

        await expectLater(
          callFunction('add', {'a': 1, 'b': 1}, onSecond),
          throwsStateError,
        );
        // The default app's Functions is untouched.
        expect(await callFunction('add', {'a': 2, 'b': 3}), 5);
      });

      test('a call that outlasts the wait keeps the app', () async {
        final call = callFunction('slow', {'ms': 7000}, onSecond);
        expect(() => deleteNamedApp(second), throwsStateError);

        // As it was: it still calls, and the one running is answered.
        expect(await callFunction('add', {'a': 2, 'b': 3}, onSecond), 5);
        expect(await call, 'done');
        deleteNamedApp(second);
      }, timeout: const Timeout(Duration(seconds: 40)));
    },
  );

  group(
    'firestore float widths',
    skip: hasFirestore ? null : 'Firestore not bound',
    () {
      test('a double survives the round trip whatever its width', () async {
        // The encoder writes the narrowest float that holds a value exactly,
        // so these go out as halves and singles rather than doubles. Reading
        // them back with cbor_value_get_double stored 1.5 as 5.14e-315 --
        // a document that looked written and was not.
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/a';
        await setDocument(path, {
          'half': 1.5,
          'negative': -0.25,
          'single': 0.1,
          'big': 1.7976931348623157e308,
          'whole': 3.0,
        });

        final doc = (await getDocument(path))!;
        expect(doc['half'], closeTo(1.5, 1e-12));
        expect(doc['negative'], closeTo(-0.25, 1e-12));
        expect(doc['single'], closeTo(0.1, 1e-12));
        expect(doc['big'], closeTo(1.7976931348623157e308, 1e295));
        // 3.0 is whole, so the encoder writes it as an integer and Firestore
        // stores an integer. Worth pinning: it is the one case where a double
        // does not come back as one.
        expect((doc['whole']! as num).toDouble(), closeTo(3.0, 1e-12));
      });

      test('a geopoint keeps its coordinates', () async {
        // Latitude and longitude are read through the same call the values
        // above were, and are just as narrow: 51.5 is a half.
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/geo';
        await setDocument(path, {
          'where': const FirestoreGeoPoint(51.5, -0.125),
        });

        final g = (await getDocument(path))!['where']! as FirestoreGeoPoint;
        expect(g.latitude, closeTo(51.5, 1e-12));
        expect(g.longitude, closeTo(-0.125, 1e-12));
      });

      test('a double increment adds what it was given', () async {
        final path = 'fw${DateTime.now().microsecondsSinceEpoch}/inc';
        await setDocument(path, {'n': 1.5});
        await setDocument(path, {
          'n': FirestoreSentinel.increment(0.25),
        }, merge: true);

        expect((await getDocument(path))!['n'], closeTo(1.75, 1e-12));
      });
    },
  );
  group('aggregates', skip: hasFirestore ? null : 'Firestore not bound', () {
    late String col;

    setUpAll(() async {
      col = 'agg${DateTime.now().microsecondsSinceEpoch}';
      // Integers, doubles, a document missing the field, and one where it is
      // not a number. The last two are skipped by the server rather than
      // treated as zero, which is what makes the average worth asserting.
      await setDocument('$col/a', {'n': 1, 'd': 1.5});
      await setDocument('$col/b', {'n': 2, 'd': 2.5});
      await setDocument('$col/c', {'n': 3, 'd': 3.5});
      await setDocument('$col/d', {'other': 'no n here'});
      await setDocument('$col/e', {'n': 'not a number'});
    });

    test('a sum of integers comes back whole', () async {
      // Firestore answers an all-integer sum with integer_value. Reading
      // only double_value would give 0 -- the same shape as the half-float
      // bug in the Variant codec, and just as quiet.
      expect(await sumCollection(col, 'n'), closeTo(6.0, 1e-9));
    });

    test('a sum of doubles keeps its fraction', () async {
      expect(await sumCollection(col, 'd'), closeTo(7.5, 1e-9));
    });

    test('an average skips what it cannot add', () async {
      // Five documents, three with a numeric n. 6/3 rather than 6/5, which
      // is what counting the other two as zero would give.
      expect(await averageCollection(col, 'n'), closeTo(2.0, 1e-9));
    });

    test('a filter narrows what is aggregated', () async {
      final sum = await sumCollection(
        col,
        'n',
        where: const [Where.greaterThan('n', 1)],
      );
      expect(sum, closeTo(5.0, 1e-9));
    });

    test('a field nothing has sums to zero', () async {
      expect(await sumCollection(col, 'absent'), 0.0);
    });

    test('an empty collection has no average', () async {
      expect(await averageCollection('agg-empty-$col', 'n'), 0.0);
    });

    test('a field is required', () async {
      await expectLater(sumCollection(col, ''), throwsA(isA<ArgumentError>()));
    });

    test('a field path the SDK rejects is an error, not a crash', () async {
      // The SDK throws on a malformed path, and an exception crossing the C
      // ABI aborts the process rather than reaching here. The query builder
      // already guards its own paths for the same reason.
      await expectLater(
        sumCollection(col, 'a//b'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('count', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('counts without fetching, and respects filters', () async {
      final coll = 'probe_c${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 4; i++) {
        await setDocument('$coll/doc$i', {
          'n': i,
          'tag': i < 2 ? 'low' : 'high',
        });
      }

      expect(await countCollection(coll), 4);
      expect(
        await countCollection(coll, where: const [Where.equalTo('tag', 'low')]),
        2,
      );
      expect(
        await countCollection(
          coll,
          where: const [Where.equalTo('tag', 'nope')],
        ),
        0,
      );

      for (var i = 0; i < 4; i++) {
        await deleteDocument('$coll/doc$i');
      }
    });

    test('an empty collection counts zero rather than failing', () async {
      expect(await countCollection('probe_c_definitely_absent'), 0);
    });
  });

  group(
    'collection groups',
    skip: hasFirestore ? null : 'Firestore not bound',
    () {
      test('finds a collection id at any depth', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final id = 'leaf$stamp';
        await setDocument('probe_cg$stamp/one/$id/x', {'n': 1});
        await setDocument('probe_cg$stamp/two/$id/y', {'n': 2});

        // A path query sees one collection; a group query sees both, which is
        // the whole distinction.
        final onePath = await queryCollection('probe_cg$stamp/one/$id');
        expect(onePath, hasLength(1));

        final group = await queryCollection(id, collectionGroup: true);
        expect(group.map((d) => d.data['n']).toSet(), {1, 2});

        await deleteDocument('probe_cg$stamp/one/$id/x');
        await deleteDocument('probe_cg$stamp/two/$id/y');
      });

      test('filters apply to a group query', () async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final id = 'leaff$stamp';
        await setDocument('probe_cg$stamp/one/$id/x', {'n': 1});
        await setDocument('probe_cg$stamp/two/$id/y', {'n': 2});

        final filtered = await queryCollection(
          id,
          collectionGroup: true,
          where: const [Where.greaterThan('n', 1)],
        );
        expect(filtered.map((d) => d.data['n']).toList(), [2]);

        await deleteDocument('probe_cg$stamp/one/$id/x');
        await deleteDocument('probe_cg$stamp/two/$id/y');
      });
    },
  );

  group('batches', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('applies every write, or none', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final a = 'probe_b/${stamp}_a';
      final b = 'probe_b/${stamp}_b';

      final batch = FirestoreBatch()
        ..set(a, {'n': 1})
        ..set(b, {'n': 2});
      await batch.commit();

      expect((await getDocument(a))!['n'], 1);
      expect((await getDocument(b))!['n'], 2);

      await (FirestoreBatch()
            ..delete(a)
            ..delete(b))
          .commit();
      expect(await getDocument(a), isNull);
      expect(await getDocument(b), isNull);
    });

    test('an empty batch is a no-op', () async {
      await FirestoreBatch().commit();
    });

    test('a rejected write fails the whole batch', () async {
      final path = 'probe_b/${DateTime.now().microsecondsSinceEpoch}_upd';
      // update on a document that does not exist is refused by Firestore, and
      // the batch it belongs to must not half-apply.
      final other = 'probe_b/${DateTime.now().microsecondsSinceEpoch}_ok';
      await expectLater(
        (FirestoreBatch()
              ..set(other, {'n': 1})
              ..update(path, {'n': 2}))
            .commit(),
        throwsA(isA<FirestoreException>()),
      );
      expect(await getDocument(other), isNull);
    });
  });

  group(
    'firestore on a named app',
    skip: hasFirestore ? null : 'Firestore not bound',
    () {
      const second = 'second-firestore';

      // Its own Auth too: the rules want a caller who is signed in, and the
      // credential Firestore sends is the one its own app holds.
      Future<void> start({bool signIn = true}) async {
        initNamedApp(
          name: second,
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
        );
        initAuth(app: second);
        useAuthEmulator(_host, authPort, app: second);
        await authStateChanges(app: second).first;
        signOut(app: second);
        initFirestore(app: second);
        useFirestoreEmulator(_host, fsPort, app: second);
        if (signIn) await signInAnonymously(app: second);
      }

      // The default app's user is left signed in: the groups after this one
      // need it.
      setUp(() async => signInAnonymously());

      tearDown(() {
        try {
          signOut(app: second);
          deleteNamedApp(second);
        } on StateError {
          // The test deleted it.
        }
      });

      String probe(String tag) =>
          'probe_named/${DateTime.now().microsecondsSinceEpoch}_$tag';

      test('it reads and writes, with references of its own', () async {
        await start();
        final path = probe('rw');
        final other = probe('ref');

        await setDocument(path, {
          'n': 1,
          'to': FirestoreReference(other),
        }, app: second);
        final back = await getDocument(path, app: second);
        expect(back!['n'], 1);
        expect((back['to']! as FirestoreReference).path, other);

        await (FirestoreBatch(app: second)..update(path, {'n': 2})).commit();
        await runTransaction((tx) async {
          final current = await tx.get(path);
          tx.update(path, {'n': (current!['n']! as int) + 1});
        }, app: second);
        expect((await getDocument(path, app: second))!['n'], 3);

        final found = await queryCollection(
          'probe_named',
          where: [Where('to', '==', FirestoreReference(other))],
          app: second,
        );
        expect(found.map((d) => d.path), [path]);
        expect(
          await countCollection(
            'probe_named',
            where: const [Where('n', '==', 3)],
            app: second,
          ),
          greaterThanOrEqualTo(1),
        );

        await deleteDocument(path, app: second);
        expect(await getDocument(path, app: second), isNull);
      });

      test('it sends its own app\'s credential', () async {
        // The default app is signed in and this one is not. The rules want a
        // caller who is, so a request carrying the default app's token would
        // get through.
        await start(signIn: false);
        expect(currentUid(), isNotNull);

        await expectLater(
          setDocument(probe('denied'), {'n': 1}, app: second),
          throwsA(isA<FirestoreException>()),
        );
      });

      test('it needs its own init', () async {
        initNamedApp(
          name: 'no-firestore',
          appId: '1:1:android:1',
          apiKey: 'emulator-does-not-check-this',
          projectId: _projectId,
        );
        addTearDown(() => deleteNamedApp('no-firestore'));

        await expectLater(
          getDocument(probe('x'), app: 'no-firestore'),
          throwsStateError,
        );
        expect(() => initFirestore(app: 'nobody'), throwsStateError);
      });

      test('deleting the app tells its listeners', () async {
        await start();
        final path = probe('watched');
        await setDocument(path, {'n': 1}, app: second);

        final events = <Object?>[];
        final errors = <Object>[];
        final sub = onDocument(
          path,
          app: second,
        ).listen(events.add, onError: errors.add);
        addTearDown(sub.cancel);
        await _until(() => events.isNotEmpty, 'the first snapshot');

        deleteNamedApp(second);
        await _until(() => errors.isNotEmpty, 'the listener to be told');
        expect('${errors.single}', contains('the app was deleted'));

        // Nothing is left to start on, and the default app's is untouched.
        await expectLater(getDocument(path, app: second), throwsStateError);
        final mine = probe('default');
        await setDocument(mine, {'n': 1});
        expect((await getDocument(mine))!['n'], 1);
        await deleteDocument(mine);
      });

      test('deleting the app ends a transaction that is open', () async {
        await start();
        final path = probe('txn');
        final entered = Completer<void>();
        final hold = Completer<void>();

        final failed = expectLater(
          runTransaction((tx) async {
            await tx.get(path);
            entered.complete();
            // Parked, as a handler waiting on something else would be.
            await hold.future;
          }, app: second),
          throwsA(
            isA<FirestoreException>().having(
              (e) => e.message,
              'message',
              contains('the app was deleted'),
            ),
          ),
        );

        await entered.future;
        deleteNamedApp(second);
        await failed;
        hold.complete();
      });

      test('deleting the app answers what was pending', () async {
        await start();
        // Asked for and deleted in the same breath. Whether the answer got
        // there first or not, there is one.
        final read = getDocument(probe('pending'), app: second);
        final write = setDocument(probe('pending'), {'n': 1}, app: second);
        deleteNamedApp(second);

        Future<String> settled(Future<Object?> f) => f.then(
          (_) => 'answered',
          onError: (Object e) => e is FirestoreException ? 'failed' : '$e',
        );
        expect(
          await Future.wait([
            settled(read),
            settled(write),
          ]).timeout(const Duration(seconds: 10)),
          everyElement(anyOf('answered', 'failed')),
        );
      });
    },
  );

  group('transactions', skip: hasFirestore ? null : 'Firestore not bound', () {
    test('reads and writes atomically', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}';
      await setDocument(path, {'n': 1});

      await runTransaction((tx) async {
        final current = await tx.get(path);
        tx.set(path, {'n': (current!['n']! as int) + 1});
      });

      expect((await getDocument(path))!['n'], 2);
      await deleteDocument(path);
    });

    test('a handler that throws leaves the document untouched', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_abort';
      await setDocument(path, {'n': 1});

      await expectLater(
        runTransaction((tx) async {
          tx.set(path, {'n': 99});
          throw StateError('changed my mind');
        }),
        throwsA(isA<StateError>()),
      );

      // The write was buffered, never applied — which is the reason writes are
      // buffered rather than sent as they are recorded.
      expect((await getDocument(path))!['n'], 1);
      await deleteDocument(path);
    });

    test('reading after writing is refused at the call site', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_order';
      await setDocument(path, {'n': 1});

      await expectLater(
        runTransaction((tx) async {
          tx.set(path, {'n': 2});
          // Firestore rejects this at commit; refusing here says which line
          // was wrong instead.
          await tx.get(path);
        }),
        throwsA(isA<StateError>()),
      );
      await deleteDocument(path);
    });

    test(
      'the handler runs again when the document changed underneath',
      () async {
        // The behavior that distinguishes a transaction from a batch, forced
        // deterministically: the first attempt reads, something else writes, and
        // Firestore must notice at commit and run the handler again.
        final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_retry';
        await setDocument(path, {'n': 1});

        var attempts = 0;
        await runTransaction((tx) async {
          attempts++;
          final current = await tx.get(path);
          if (attempts == 1) {
            // Behind the transaction's back, after it has read.
            await setDocument(path, {'n': 100});
          }
          tx.set(path, {'n': (current!['n']! as int) + 1});
        });

        expect(
          attempts,
          greaterThan(1),
          reason: 'the handler should have rerun',
        );
        // 101, not 2: the second attempt read the value the interloper wrote.
        expect((await getDocument(path))!['n'], 101);
        await deleteDocument(path);
      },
    );

    test('a transaction with no writes still completes', () async {
      final path = 'probe_t/${DateTime.now().microsecondsSinceEpoch}_read';
      await setDocument(path, {'n': 7});
      Map<String, Object?>? seen;
      await runTransaction((tx) async {
        seen = await tx.get(path);
      });
      expect(seen!['n'], 7);
      await deleteDocument(path);
    });
  });

  test(
    'a document that was never written reads as absent, not empty',
    skip: hasFirestore ? null : 'Firestore not bound',
    () async {
      expect(await getDocument('probe/definitely-not-there'), isNull);
    },
  );
}

/// Polls until [ready], rather than sleeping a guessed interval.
Future<void> _until(bool Function() ready, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Waits for [done], which an event from another thread makes true.
Future<void> _eventually(bool Function() done) async {
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
  int port,
  String method,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://$_host:$port/identitytoolkit.googleapis.com/v1/'
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

/// The mails the Auth emulator would have sent.
Future<List<Map<String, Object?>>> _oobCodes(int port) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse(
        'http://$_host:$port/emulator/v1/projects/$_projectId/oobCodes',
      ),
    );
    final response = await request.close();
    final body = jsonDecode(await utf8.decodeStream(response)) as Map;
    return [
      for (final code in body['oobCodes'] as List? ?? const [])
        (code as Map).cast<String, Object?>(),
    ];
  } finally {
    client.close();
  }
}

/// Creates a password account in the Auth emulator, returning its uid.
Future<String> _createAccount(int port, String email, String name) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'http://$_host:$port/identitytoolkit.googleapis.com/v1/'
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
