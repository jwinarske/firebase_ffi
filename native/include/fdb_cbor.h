/* SPDX-FileCopyrightText: 2026 Joel Winarske
 * SPDX-License-Identifier: Apache-2.0
 *
 * The CBOR codec, declared so it can be tested.
 *
 * These were file-local until a sizing bug shipped in both of them: the
 * encoders stop at the first error, so a measuring pass against a null buffer
 * abandoned the walk at the first container and the real pass then overflowed.
 * Nothing outside the translation unit could reach them, so nothing could test
 * them, and the failure only appeared against a live backend.
 */
#ifndef FDB_CBOR_H_
#define FDB_CBOR_H_

#include <cstdint>
#include <vector>

#if defined(FDB_HAVE_FIREBASE)
#include "firebase/variant.h"
#endif
#if defined(FDB_HAVE_FIRESTORE)
#include "firebase/firestore.h"
#endif

namespace fdb {

#if defined(FDB_HAVE_FIREBASE)
/* Realtime Database values. Returns false only when encoding fails. */
bool SerializeVariant(const firebase::Variant& v, std::vector<uint8_t>& out);
#endif

#if defined(FDB_HAVE_FIRESTORE)
/* A Firestore document, both directions. */
bool SerializeDocument(const firebase::firestore::MapFieldValue& m,
                       std::vector<uint8_t>& out);
bool ParseDocumentCbor(const uint8_t* cbor, size_t len,
                       firebase::firestore::MapFieldValue* out);
#endif

}  // namespace fdb

#endif  /* FDB_CBOR_H_ */
