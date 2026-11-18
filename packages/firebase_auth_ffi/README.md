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
`providerData`. It is the SDK's cached copy. `reload` is not bound, so a
change made elsewhere shows up at the next sign-in.

A cached token is returned without a request — the SDK answers from its own
copy while more than five minutes remain — so this works against the emulator
right after a sign-in. A *refresh* does not: `SecureTokenRequest` builds
`securetoken.googleapis.com` from a compile-time host and overwrites the
emulator URL its base class applied, so `getIdToken(true)` leaves the emulator
and fails on a token the emulator minted.

`authStateChanges`, `idTokenChanges` and `userChanges` come from the SDK's own
listeners. Each starts with whoever is signed in, including a session the SDK
restored from the secure store. `idTokenChanges` and `userChanges` also report
a refreshed token. They are otherwise the same, since no profile update is
bound.

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

## What it does not

Phone, Game Center and Play Games credentials, and an email-link
credential: `signInWithCredential` throws `UnimplementedError` for
each. `signInWithProvider` and `signInWithPopup` are not bound, so there is no
browser flow. Account management -- `reload`, the `update` calls, linking,
password reset, `delete` -- is not bound either.

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
