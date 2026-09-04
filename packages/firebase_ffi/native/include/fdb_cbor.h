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
#include <map>
#include <string>
#include <vector>

#include "firebase_bridge.h"  /* FDB_EXPORT */

#if defined(FDB_HAVE_FIREBASE)
#include "firebase/database/data_snapshot.h"
#include "firebase/variant.h"
#endif
#if defined(FDB_HAVE_FIRESTORE)
#include "firebase/firestore.h"
#endif
#if defined(FDB_HAVE_STORAGE)
#include "firebase/storage/metadata.h"
#endif

namespace fdb {

#if defined(FDB_HAVE_FIREBASE)
/* Realtime Database values. Returns false only when encoding fails. */
FDB_EXPORT bool SerializeVariant(const firebase::Variant& v, std::vector<uint8_t>& out);

/* The other direction, and the string-keyed map shape that Functions and
 * Remote Config both work in. */
FDB_EXPORT bool ParseVariant(const uint8_t* cbor, size_t len,
                             firebase::Variant* out);
FDB_EXPORT bool ParseVariantMap(const uint8_t* cbor, size_t len,
                                std::map<std::string, firebase::Variant>* out);
// Encodes a snapshot's child keys in query order: nested [key, sub | null]
// pairs. The value alone cannot carry it — Variant maps sort by key.
FDB_EXPORT bool SerializeOrder(const firebase::database::DataSnapshot& snap,
                               std::vector<uint8_t>& out);

FDB_EXPORT bool SerializeVariantMap(
    const std::map<std::string, firebase::Variant>& m,
    std::vector<uint8_t>& out);
#endif

#if defined(FDB_HAVE_FIRESTORE)
/* A Firestore document, both directions. */
FDB_EXPORT bool SerializeDocument(const firebase::firestore::MapFieldValue& m,
                       std::vector<uint8_t>& out);
FDB_EXPORT bool ParseDocumentCbor(const uint8_t* cbor, size_t len,
                       firebase::firestore::MapFieldValue* out);
#endif

#if defined(FDB_HAVE_STORAGE)
/* Object metadata, one direction: the SDK returns it, nothing sends it back
 * in this form. Absent fields are omitted rather than encoded empty. */
FDB_EXPORT bool SerializeMetadata(const firebase::storage::Metadata& m,
                       std::vector<uint8_t>& out);
#endif

}  // namespace fdb

#endif  /* FDB_CBOR_H_ */
