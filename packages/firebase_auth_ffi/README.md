# firebase_auth_ffi

The `firebase_auth` implementation for **desktop Linux**, backed by the Firebase C++
SDK through [`firebase_ffi`](../firebase_ffi).

It registers itself, so your code calls `firebase_auth` and never mentions this
package or `firebase_ffi`:

```yaml
dependencies:
  firebase_auth: any
  firebase_core_ffi: ^0.1.0   # registers on Linux
  firebase_auth_ffi: ^0.1.0
```

## What it covers

Anonymous, custom-token and email/password sign-in, creating a password
account, the current user, and the ID token an app
needs to authenticate against a backend of its own — `getIdToken` and
`getIdTokenResult`, the second reading its claims out of the token itself.

`User` carries what the SDK holds for the account: `email`, `displayName`,
`photoURL`, `phoneNumber`, `isAnonymous`, `emailVerified`, `metadata` and
`providerData`. It is the SDK's cached copy, and `reload` brings it up to
date. A `User` is a snapshot: after a call that changes the account, read
`FirebaseAuth.currentUser` again.

A cached token is returned without a request — the SDK answers from its own
copy while more than five minutes remain. `getIdToken(true)` asks for a new
one.

`authStateChanges`, `idTokenChanges` and `userChanges` come from the SDK's own
listeners. Each starts with whoever is signed in, including a session the SDK
restored from the secure store. `idTokenChanges` and `userChanges` also report
a refreshed token.

A failure is a `FirebaseAuthException` with the code the other platforms use:
`invalid-custom-token`, `user-disabled`, `network-request-failed`. The table is
the FlutterFire Windows plugin's, which sits on the same SDK. An error it has
no name for is `unknown-error`, and the message ends with the SDK's
`AuthError` number.

`signInWithCredential` takes a credential the app got some other way -- the
desktop SDK runs no sign-in UI of its own:

| Credential | Needs |
| --- | --- |
| `EmailAuthProvider.credential` | email and password |
| `GoogleAuthProvider.credential` | an ID token or an access token |
| `FacebookAuthProvider.credential` | an access token |
| `GithubAuthProvider.credential` | an access token |
| `TwitterAuthProvider.credential` | an access token and a secret |
| `OAuthProvider(id).credential`, for Apple, Microsoft, Yahoo or any other id | an ID token, with a raw nonce or an access token |

One that lacks what its provider needs fails as `invalid-credential`. That
includes `YahooAuthProvider.credential`, which carries an access token and no
ID token.

Account management, on the signed-in user:

| Call | Notes |
| --- | --- |
| `reload` | brings the SDK's copy of the account up to date |
| `updateDisplayName`, `updatePhotoURL` | null removes the field |
| `updatePassword` | |
| `sendEmailVerification`, `verifyBeforeUpdateEmail` | |
| `linkWithCredential`, `unlink` | the credentials `signInWithCredential` takes |
| `reauthenticateWithCredential` | what the server asks for before a delete or a password change on an old sign-in |
| `delete` | signs out |

`FirebaseAuth.sendPasswordResetEmail` needs nobody signed in. `userChanges`
reports the user again after `reload`, a profile update, a link or an unlink.
A `User` kept from before a sign-out fails these as `no-signed-in-user`.

Two of these need the SDK built with this repo's patches to work against the
Auth emulator: a token refresh, and linking a *password* credential. Stock
13.13.1 sends both to production whatever `useAuthEmulator` said, where a token
the emulator minted is refused. Upstream fixed that in 14.1.0, and
`firebase_ffi`'s patch set carries the fix for 13.13.1. Neither is affected
against a real project.

A named app has its own Auth: `FirebaseAuth.instanceFor(app: second)` signs in
its own user and has its own streams, apart from the default app's. The SDK
keeps a session per app name, so a named app restores its own. Deleting the app
ends its streams.

## What it does not

Phone, Game Center and Play Games credentials, and an email-link
credential: `signInWithCredential`, `linkWithCredential` and
`reauthenticateWithCredential` throw `UnimplementedError` for each.
`signInWithProvider`, `linkWithProvider` and `signInWithPopup` are not bound,
so there is no browser flow. Nor are `ActionCodeSettings`: a mail call given
one throws, since dropping it would send a link the app did not ask for.
`confirmPasswordReset`, `updatePhoneNumber` and multi-factor are not bound.

A method that is not bound throws rather than returning something plausible.
Silence would be worse: an app cannot tell a value it did not get from one that
does not exist.

## Requirements

`firebase_ffi` needs a prebuilt Firebase C++ SDK — this package does not
download or build one. See its [README](../firebase_ffi/README.md) for how to
point at an install prefix.

Linux only. On any other platform the FlutterFire plugin uses its own
implementation and this package is not registered.

## License

Apache-2.0. See [LICENSE](LICENSE).
