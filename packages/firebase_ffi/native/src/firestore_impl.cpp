// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Cloud Firestore, on the same firebase::App as Auth and Database.
//
// Documents cross as CBOR in both directions, which is the reason this file is
// shorter than the Database one: the encoding is a library's problem on each
// side, not a hand-written pair that has to agree.
//
// The mapping is in firebase_bridge.h. What is worth restating here: sentinels
// are instructions, not values. Firestore never returns them, so DecodeValue
// accepts them (a write may contain one) and EncodeValue never produces one.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase_bridge.h"

#include "firebase/app.h"
#include "firebase/firestore.h"

namespace {

using ::firebase::firestore::DocumentReference;
using ::firebase::firestore::DocumentSnapshot;
using ::firebase::firestore::FieldValue;
using ::firebase::firestore::Firestore;
using ::firebase::firestore::ListenerRegistration;
using ::firebase::firestore::MapFieldValue;
using ::firebase::firestore::Query;
using ::firebase::firestore::SetOptions;

std::mutex g_mutex;
Firestore* g_firestore = nullptr;
int64_t g_next_listener = 1;
std::unordered_map<int64_t, ListenerRegistration> g_listeners;

// --- encode: FieldValue -> CBOR ------------------------------------------

bool EncodeValue(const FieldValue& v, CborEncoder* enc);

bool EncodeMap(const MapFieldValue& m, CborEncoder* enc) {
  CborEncoder map;
  if (cbor_encoder_create_map(enc, &map, m.size()) != CborNoError) return false;
  for (const auto& entry : m) {
    if (cbor_encode_text_string(&map, entry.first.c_str(),
                                entry.first.size()) != CborNoError) {
      return false;
    }
    if (!EncodeValue(entry.second, &map)) return false;
  }
  return cbor_encoder_close_container(enc, &map) == CborNoError;
}

bool EncodeValue(const FieldValue& v, CborEncoder* enc) {
  switch (v.type()) {
    case FieldValue::Type::kNull:
      return cbor_encode_null(enc) == CborNoError;
    case FieldValue::Type::kBoolean:
      return cbor_encode_boolean(enc, v.boolean_value()) == CborNoError;
    case FieldValue::Type::kInteger:
      return cbor_encode_int(enc, v.integer_value()) == CborNoError;
    case FieldValue::Type::kDouble:
      return cbor_encode_double(enc, v.double_value()) == CborNoError;
    case FieldValue::Type::kString: {
      const std::string s = v.string_value();
      return cbor_encode_text_string(enc, s.c_str(), s.size()) == CborNoError;
    }
    case FieldValue::Type::kBlob:
      return cbor_encode_byte_string(enc, v.blob_value(), v.blob_size()) ==
             CborNoError;
    case FieldValue::Type::kTimestamp: {
      const auto ts = v.timestamp_value();
      CborEncoder pair;
      if (cbor_encode_tag(enc, FDB_CBOR_TAG_TIMESTAMP) != CborNoError ||
          cbor_encoder_create_array(enc, &pair, 2) != CborNoError ||
          cbor_encode_int(&pair, ts.seconds()) != CborNoError ||
          cbor_encode_int(&pair, ts.nanoseconds()) != CborNoError) {
        return false;
      }
      return cbor_encoder_close_container(enc, &pair) == CborNoError;
    }
    case FieldValue::Type::kGeoPoint: {
      const auto gp = v.geo_point_value();
      CborEncoder pair;
      if (cbor_encode_tag(enc, FDB_CBOR_TAG_GEOPOINT) != CborNoError ||
          cbor_encoder_create_array(enc, &pair, 2) != CborNoError ||
          cbor_encode_double(&pair, gp.latitude()) != CborNoError ||
          cbor_encode_double(&pair, gp.longitude()) != CborNoError) {
        return false;
      }
      return cbor_encoder_close_container(enc, &pair) == CborNoError;
    }
    case FieldValue::Type::kReference: {
      const std::string path = v.reference_value().path();
      return cbor_encode_tag(enc, FDB_CBOR_TAG_REFERENCE) == CborNoError &&
             cbor_encode_text_string(enc, path.c_str(), path.size()) ==
                 CborNoError;
    }
    case FieldValue::Type::kArray: {
      const auto items = v.array_value();
      CborEncoder array;
      if (cbor_encoder_create_array(enc, &array, items.size()) != CborNoError) {
        return false;
      }
      for (const auto& item : items) {
        if (!EncodeValue(item, &array)) return false;
      }
      return cbor_encoder_close_container(enc, &array) == CborNoError;
    }
    case FieldValue::Type::kMap:
      return EncodeMap(v.map_value(), enc);
    default:
      // Sentinels are never returned by Firestore. Reaching here means the SDK
      // produced one, which would be a change in its behaviour, not ours.
      return cbor_encode_null(enc) == CborNoError;
  }
}

}  // namespace

namespace fdb {

bool SerializeDocument(const MapFieldValue& m, std::vector<uint8_t>& out) {
  // Grow-and-retry rather than a sizing pass against a null buffer: the
  // encoders here stop at the first error, so a measuring pass abandons the
  // walk as soon as the first container reports CborErrorOutOfMemory and only
  // the bytes written before that get counted. The real pass then overflows a
  // buffer sized from a partial count.
  //
  // Doubling from a reasonable start costs at most a few wasted encodes and
  // cannot under-count, because success is the loop's only exit.
  size_t cap = 512;
  for (int attempt = 0; attempt < 16; ++attempt) {
    out.assign(cap, 0);
    CborEncoder enc;
    cbor_encoder_init(&enc, out.data(), cap, 0);
    if (EncodeMap(m, &enc)) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    cap *= 2;
  }
  out.clear();
  return false;
}

}  // namespace fdb

namespace {

// --- decode: CBOR -> FieldValue -----------------------------------------
//
// Accepts sentinels, unlike the encoder: a write may legitimately contain
// FieldValue::Delete() or ServerTimestamp(), which is what they are for.

bool DecodeValue(CborValue* it, FieldValue* out);

bool DecodeMap(CborValue* it, MapFieldValue* out) {
  CborValue entry;
  if (cbor_value_enter_container(it, &entry) != CborNoError) return false;
  while (!cbor_value_at_end(&entry)) {
    if (!cbor_value_is_text_string(&entry)) return false;
    char* key = nullptr;
    size_t key_len = 0;
    if (cbor_value_dup_text_string(&entry, &key, &key_len, &entry) !=
        CborNoError) {
      return false;
    }
    FieldValue value;
    const bool ok = DecodeValue(&entry, &value);
    if (ok) out->emplace(std::string(key, key_len), std::move(value));
    std::free(key);
    if (!ok) return false;
  }
  return cbor_value_leave_container(it, &entry) == CborNoError;
}

// A tagged item: the tag says which Firestore type the payload describes.
bool DecodeTagged(CborValue* it, FieldValue* out) {
  CborTag tag = 0;
  if (cbor_value_get_tag(it, &tag) != CborNoError) return false;
  if (cbor_value_advance_fixed(it) != CborNoError) return false;

  switch (tag) {
    case FDB_CBOR_TAG_DELETE:
      *out = FieldValue::Delete();
      return cbor_value_advance(it) == CborNoError;
    case FDB_CBOR_TAG_SERVER_TIMESTAMP:
      *out = FieldValue::ServerTimestamp();
      return cbor_value_advance(it) == CborNoError;
    case FDB_CBOR_TAG_TIMESTAMP:
    case FDB_CBOR_TAG_GEOPOINT: {
      if (!cbor_value_is_array(it)) return false;
      CborValue pair;
      if (cbor_value_enter_container(it, &pair) != CborNoError) return false;
      double a = 0, b = 0;
      int64_t ia = 0, ib = 0;
      if (tag == FDB_CBOR_TAG_TIMESTAMP) {
        if (cbor_value_get_int64(&pair, &ia) != CborNoError ||
            cbor_value_advance(&pair) != CborNoError ||
            cbor_value_get_int64(&pair, &ib) != CborNoError ||
            cbor_value_advance(&pair) != CborNoError) {
          return false;
        }
        *out = FieldValue::Timestamp(
            firebase::Timestamp(ia, static_cast<int32_t>(ib)));
      } else {
        if (cbor_value_get_double(&pair, &a) != CborNoError ||
            cbor_value_advance(&pair) != CborNoError ||
            cbor_value_get_double(&pair, &b) != CborNoError ||
            cbor_value_advance(&pair) != CborNoError) {
          return false;
        }
        *out = FieldValue::GeoPoint(firebase::firestore::GeoPoint(a, b));
      }
      return cbor_value_leave_container(it, &pair) == CborNoError;
    }
    case FDB_CBOR_TAG_REFERENCE: {
      char* path = nullptr;
      size_t len = 0;
      if (cbor_value_dup_text_string(it, &path, &len, it) != CborNoError) {
        return false;
      }
      *out = FieldValue::Reference(
          g_firestore->Document(std::string(path, len)));
      std::free(path);
      return true;
    }
    // The payload is a one-element array rather than a bare number: Dart's
    // CBOR package drops tags when it normalises an integer to a small int, so
    // a tagged bare int would arrive here untagged.
    case FDB_CBOR_TAG_INCREMENT_INT:
    case FDB_CBOR_TAG_INCREMENT_DOUBLE: {
      if (!cbor_value_is_array(it)) return false;
      CborValue elem;
      if (cbor_value_enter_container(it, &elem) != CborNoError) return false;
      if (tag == FDB_CBOR_TAG_INCREMENT_INT) {
        int64_t by = 0;
        if (cbor_value_get_int64(&elem, &by) != CborNoError) return false;
        // Increment(), not IntegerIncrement(): the typed entry points are
        // private, reached through the public template.
        *out = FieldValue::Increment(by);
      } else {
        double by = 0;
        if (cbor_value_get_double(&elem, &by) != CborNoError) return false;
        *out = FieldValue::Increment(by);
      }
      if (cbor_value_advance(&elem) != CborNoError) return false;
      return cbor_value_leave_container(it, &elem) == CborNoError;
    }
    case FDB_CBOR_TAG_ARRAY_UNION:
    case FDB_CBOR_TAG_ARRAY_REMOVE: {
      if (!cbor_value_is_array(it)) return false;
      CborValue elem;
      if (cbor_value_enter_container(it, &elem) != CborNoError) return false;
      std::vector<FieldValue> items;
      while (!cbor_value_at_end(&elem)) {
        FieldValue v;
        if (!DecodeValue(&elem, &v)) return false;
        items.push_back(std::move(v));
      }
      *out = tag == FDB_CBOR_TAG_ARRAY_UNION
                 ? FieldValue::ArrayUnion(std::move(items))
                 : FieldValue::ArrayRemove(std::move(items));
      return cbor_value_leave_container(it, &elem) == CborNoError;
    }
    default:
      // An unknown tag is a message this build does not understand. Refusing
      // beats writing the payload without the meaning its tag carried.
      return false;
  }
}

bool DecodeValue(CborValue* it, FieldValue* out) {
  if (cbor_value_is_tag(it)) return DecodeTagged(it, out);

  switch (cbor_value_get_type(it)) {
    case CborNullType:
      *out = FieldValue::Null();
      return cbor_value_advance_fixed(it) == CborNoError;
    case CborBooleanType: {
      bool b = false;
      if (cbor_value_get_boolean(it, &b) != CborNoError) return false;
      *out = FieldValue::Boolean(b);
      return cbor_value_advance_fixed(it) == CborNoError;
    }
    case CborIntegerType: {
      int64_t i = 0;
      if (cbor_value_get_int64(it, &i) != CborNoError) return false;
      *out = FieldValue::Integer(i);
      return cbor_value_advance_fixed(it) == CborNoError;
    }
    case CborDoubleType:
    case CborFloatType:
    case CborHalfFloatType: {
      double d = 0;
      if (cbor_value_get_double(it, &d) != CborNoError) return false;
      *out = FieldValue::Double(d);
      return cbor_value_advance_fixed(it) == CborNoError;
    }
    case CborTextStringType: {
      char* s = nullptr;
      size_t len = 0;
      if (cbor_value_dup_text_string(it, &s, &len, it) != CborNoError) {
        return false;
      }
      *out = FieldValue::String(std::string(s, len));
      std::free(s);
      return true;
    }
    case CborByteStringType: {
      uint8_t* b = nullptr;
      size_t len = 0;
      if (cbor_value_dup_byte_string(it, &b, &len, it) != CborNoError) {
        return false;
      }
      *out = FieldValue::Blob(b, len);
      std::free(b);
      return true;
    }
    case CborArrayType: {
      CborValue elem;
      if (cbor_value_enter_container(it, &elem) != CborNoError) return false;
      std::vector<FieldValue> items;
      while (!cbor_value_at_end(&elem)) {
        FieldValue v;
        if (!DecodeValue(&elem, &v)) return false;
        items.push_back(std::move(v));
      }
      *out = FieldValue::Array(std::move(items));
      return cbor_value_leave_container(it, &elem) == CborNoError;
    }
    case CborMapType: {
      MapFieldValue m;
      if (!DecodeMap(it, &m)) return false;
      *out = FieldValue::Map(std::move(m));
      return true;
    }
    default:
      return false;
  }
}


// --- Queries ---------------------------------------------------------------
//
// A query arrives as one CBOR map describing what to run, rather than as a
// chain of ABI calls:
//
//   {"where":   [[field, op, value], ...],
//    "orderBy": [[field, "asc"|"desc"], ...],
//    "limit": n, "limitToLast": n}
//
// One call instead of one per clause. A query is a value; building it across
// calls would need per-query state here, and a handle to leak when a caller
// goes away mid-build. Values inside `where` use the same tagged encoding as
// documents, so filtering on a timestamp or geopoint needs nothing extra.
bool ApplyWhere(Query* q, const std::string& field, const std::string& op,
                const FieldValue& v) {
  if (op == "==") {
    *q = q->WhereEqualTo(field, v);
  } else if (op == "!=") {
    *q = q->WhereNotEqualTo(field, v);
  } else if (op == "<") {
    *q = q->WhereLessThan(field, v);
  } else if (op == "<=") {
    *q = q->WhereLessThanOrEqualTo(field, v);
  } else if (op == ">") {
    *q = q->WhereGreaterThan(field, v);
  } else if (op == ">=") {
    *q = q->WhereGreaterThanOrEqualTo(field, v);
  } else if (op == "array-contains") {
    *q = q->WhereArrayContains(field, v);
  } else if (op == "array-contains-any") {
    if (!v.is_array()) return false;
    *q = q->WhereArrayContainsAny(field, v.array_value());
  } else if (op == "in") {
    if (!v.is_array()) return false;
    *q = q->WhereIn(field, v.array_value());
  } else if (op == "not-in") {
    if (!v.is_array()) return false;
    *q = q->WhereNotIn(field, v.array_value());
  } else {
    // An operator this ABI does not know is refused, not dropped: a filter
    // silently ignored returns more documents than were asked for, and that
    // reads as data rather than as an error.
    return false;
  }
  return true;
}

bool ReadText(CborValue* it, std::string* out) {
  if (!cbor_value_is_text_string(it)) return false;
  char* buf = nullptr;
  size_t len = 0;
  if (cbor_value_dup_text_string(it, &buf, &len, it) != CborNoError) {
    return false;
  }
  out->assign(buf, len);
  std::free(buf);
  return true;
}

// One [field, op, value] triple.
bool ApplyWhereClause(CborValue* clause, Query* q) {
  CborValue it;
  if (cbor_value_enter_container(clause, &it) != CborNoError) return false;
  std::string field;
  std::string op;
  FieldValue value;
  if (!ReadText(&it, &field)) return false;
  if (!ReadText(&it, &op)) return false;
  if (!DecodeValue(&it, &value)) return false;
  return ApplyWhere(q, field, op, value);
}

// One [field, "asc"|"desc"] pair.
bool ApplyOrderClause(CborValue* clause, Query* q) {
  CborValue it;
  if (cbor_value_enter_container(clause, &it) != CborNoError) return false;
  std::string field;
  std::string dir;
  if (!ReadText(&it, &field)) return false;
  if (!ReadText(&it, &dir)) return false;
  if (dir != "asc" && dir != "desc") return false;
  *q = q->OrderBy(field, dir == "desc" ? Query::Direction::kDescending
                                       : Query::Direction::kAscending);
  return true;
}

// A cursor: the values marking where a page starts or ends, one per orderBy
// clause. Firestore requires that correspondence, and rejects a mismatch
// itself rather than guessing which ordering a value belongs to.
bool ReadCursorValues(CborValue* array, std::vector<FieldValue>* out) {
  if (!cbor_value_is_array(array)) return false;
  CborValue elem;
  if (cbor_value_enter_container(array, &elem) != CborNoError) return false;
  while (!cbor_value_at_end(&elem)) {
    FieldValue v;
    if (!DecodeValue(&elem, &v)) return false;
    out->push_back(v);
  }
  return true;
}

bool ApplyClauseArray(CborValue* array, bool (*apply)(CborValue*, Query*),
                      Query* q) {
  if (!cbor_value_is_array(array)) return false;
  CborValue elem;
  if (cbor_value_enter_container(array, &elem) != CborNoError) return false;
  while (!cbor_value_at_end(&elem)) {
    if (!cbor_value_is_array(&elem)) return false;
    CborValue clause = elem;
    if (!apply(&clause, q)) return false;
    if (cbor_value_advance(&elem) != CborNoError) return false;
  }
  return true;
}

// The documents of a result, each with the id a caller needs to address it
// again. A bare list of bodies would be unusable: nothing in a document says
// where it lives.
bool SerializeQueryResult(const firebase::firestore::QuerySnapshot& snap,
                          std::vector<uint8_t>& out) {
  size_t capacity = 4096;
  for (int attempt = 0; attempt < 12; ++attempt) {
    out.assign(capacity, 0);
    CborEncoder enc;
    cbor_encoder_init(&enc, out.data(), out.size(), 0);
    CborEncoder array;
    cbor_encoder_create_array(&enc, &array, CborIndefiniteLength);
    for (const DocumentSnapshot& doc : snap.documents()) {
      CborEncoder entry;
      cbor_encoder_create_map(&array, &entry, CborIndefiniteLength);
      cbor_encode_text_stringz(&entry, "id");
      cbor_encode_text_stringz(&entry, doc.id().c_str());
      cbor_encode_text_stringz(&entry, "path");
      cbor_encode_text_stringz(&entry, doc.reference().path().c_str());
      cbor_encode_text_stringz(&entry, "data");
      EncodeMap(doc.GetData(), &entry);
      cbor_encoder_close_container(&array, &entry);
    }
    cbor_encoder_close_container(&enc, &array);

    const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
    if (extra == 0) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    // Grow and retry, for the reason the other encoders do: measuring against
    // a null buffer needs the walk to continue past the first overflow, and
    // ours stop at it.
    capacity = (capacity + extra) * 2;
  }
  out.clear();
  return false;
}

}  // namespace

namespace {

// Posts [ok, code, message] — the shape Auth already uses for a completed
// operation, so the Dart side awaits it the same way.
void PostOutcome(Dart_Port_DL port, bool ok, int code,
                 const std::string& message) {
  Dart_CObject c_ok{}, c_code{}, c_msg{};
  c_ok.type = Dart_CObject_kBool;
  c_ok.value.as_bool = ok;
  c_code.type = Dart_CObject_kInt64;
  c_code.value.as_int64 = code;
  c_msg.type = Dart_CObject_kString;
  c_msg.value.as_string = const_cast<char*>(message.c_str());

  Dart_CObject* items[3] = {&c_ok, &c_code, &c_msg};
  Dart_CObject arr{};
  arr.type = Dart_CObject_kArray;
  arr.value.as_array.length = 3;
  arr.value.as_array.values = items;
  Dart_PostCObject_DL(port, &arr);
}

// Posts a document as a snapshot buffer: the same header the Database uses,
// then the CBOR map. An empty payload means the document does not exist,
// which is distinct from an empty document.
void PostDocument(Dart_Port_DL port, int64_t seq,
                  const std::vector<uint8_t>& payload) {
  const size_t total = sizeof(FdbSnapshotHeader) + payload.size();
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) return;

  FdbSnapshotHeader header{};
  header.magic = 0xFDB50000u;
  header.version = 1u;
  header.seq = seq;
  header.value_len = static_cast<uint32_t>(payload.size());
  header.posted_ns = fdb_now_ns();
  std::memcpy(buf, &header, sizeof(header));
  if (!payload.empty()) {
    std::memcpy(buf + sizeof(header), payload.data(), payload.size());
  }

  Dart_CObject obj{};
  obj.type = Dart_CObject_kExternalTypedData;
  obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_external_typed_data.length = static_cast<intptr_t>(total);
  obj.value.as_external_typed_data.data = buf;
  obj.value.as_external_typed_data.peer = buf;
  obj.value.as_external_typed_data.callback =
      [](void*, void* peer) { std::free(peer); };
  Dart_PostCObject_DL(port, &obj);
}

// Decodes a CBOR map into the document body a write applies.
}  // namespace

namespace fdb {

bool ParseDocumentCbor(const uint8_t* cbor, size_t len, MapFieldValue* out) {
  CborParser parser;
  CborValue it;
  if (cbor_parser_init(cbor, len, 0, &parser, &it) != CborNoError) return false;
  if (!cbor_value_is_map(&it)) return false;
  return DecodeMap(&it, out);
}

}  // namespace fdb

extern "C" {

FDB_EXPORT int32_t fdb_have_firestore(void) { return 1; }

// Point Firestore at a local emulator. Firestore has no UseEmulator(): the
// route is a host override with TLS off, and it has to happen before the first
// operation, because settings are frozen once the client starts.
FDB_EXPORT int64_t fdb_fs_use_emulator(const char* host, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  firebase::firestore::Settings settings = g_firestore->settings();
  settings.set_host(std::string(host) + ":" + std::to_string(port));
  settings.set_ssl_enabled(false);
  settings.set_persistence_enabled(false);
  g_firestore->set_settings(settings);
  return 0;
}

FDB_EXPORT int64_t fdb_fs_init(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore != nullptr) return 0;
  firebase::App* app = fdb_current_app();
  if (app == nullptr) return -1;
  firebase::InitResult result;
  g_firestore = Firestore::GetInstance(app, &result);
  if (g_firestore == nullptr || result != firebase::kInitResultSuccess) {
    return -2;
  }
  return 0;
}

FDB_EXPORT int64_t fdb_fs_set(const char* doc_path, const uint8_t* cbor,
                              size_t len, int32_t merge, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (doc_path == nullptr || cbor == nullptr) return -2;

  MapFieldValue data;
  if (!fdb::ParseDocumentCbor(cbor, len, &data)) return -3;

  g_firestore->Document(doc_path)
      .Set(data, merge != 0 ? SetOptions::Merge() : SetOptions())
      .OnCompletion([port](const firebase::Future<void>& f) {
        PostOutcome(static_cast<Dart_Port_DL>(port), f.error() == 0, f.error(),
                    f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Builds a query from a collection path and a spec. Shared by the one-shot
// read and the listener, so there is one parser rather than two that can
// disagree about what a spec means.
//
// Caller holds g_mutex. Returns 0, or the negative code the ABI reports.
static int BuildQuery(const char* collection_path, const uint8_t* spec,
                      size_t spec_len, Query* out) {
  // Building a query can throw: the SDK validates field paths and rejects a
  // malformed one with std::invalid_argument, which crossing this boundary
  // would abort the process rather than reach Dart. A caller's mistake must
  // come back as an error code, not as SIGABRT.
  try {
    Query query = g_firestore->Collection(collection_path);

    // An empty spec is a plain collection read. Anything else is applied
    // before the call goes out: a spec that does not parse must not run as a
    // weaker query, because the caller would get more documents and no error.
    if (spec != nullptr && spec_len != 0) {
      CborParser parser;
      CborValue map;
      if (cbor_parser_init(spec, spec_len, 0, &parser, &map) != CborNoError ||
          !cbor_value_is_map(&map)) {
        return -3;
      }
      CborValue entry;
      if (cbor_value_enter_container(&map, &entry) != CborNoError) return -3;
      while (!cbor_value_at_end(&entry)) {
        std::string key;
        if (!ReadText(&entry, &key)) return -3;
        if (key == "where") {
          if (!ApplyClauseArray(&entry, ApplyWhereClause, &query)) return -3;
        } else if (key == "orderBy") {
          if (!ApplyClauseArray(&entry, ApplyOrderClause, &query)) return -3;
        } else if (key == "startAt" || key == "startAfter" ||
                   key == "endAt" || key == "endBefore") {
          std::vector<FieldValue> values;
          if (!ReadCursorValues(&entry, &values) || values.empty()) return -3;
          if (key == "startAt") {
            query = query.StartAt(values);
          } else if (key == "startAfter") {
            query = query.StartAfter(values);
          } else if (key == "endAt") {
            query = query.EndAt(values);
          } else {
            query = query.EndBefore(values);
          }
        } else if (key == "limit" || key == "limitToLast") {
          int64_t n = 0;
          if (!cbor_value_is_integer(&entry) ||
              cbor_value_get_int64(&entry, &n) != CborNoError || n <= 0 ||
              n > INT32_MAX) {
            return -3;
          }
          query = key == "limit" ? query.Limit(static_cast<int32_t>(n))
                                 : query.LimitToLast(static_cast<int32_t>(n));
        } else {
          // Refused rather than skipped, for the same reason an unknown
          // operator is: a constraint that quietly does nothing widens the
          // result.
          return -3;
        }
        if (cbor_value_advance(&entry) != CborNoError) return -3;
      }
    }
    *out = query;
    return 0;
  } catch (const std::exception& e) {
    // -4 rather than -3: the spec parsed, the SDK refused it. A field path
    // with a '/' or '[' in it lands here.
    std::fprintf(stderr, "fdb_fs_query: %s\n", e.what());
    return -4;
  }
}

FDB_EXPORT int64_t fdb_fs_query(const char* collection_path,
                               const uint8_t* spec, size_t spec_len,
                               int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (collection_path == nullptr) return -2;

  Query query = g_firestore->Collection("_");
  const int rc = BuildQuery(collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  query.Get().OnCompletion(
      [port](const firebase::Future<firebase::firestore::QuerySnapshot>& f) {
        std::vector<uint8_t> payload;
        if (f.error() != 0 || f.result() == nullptr) {
          PostDocument(static_cast<Dart_Port_DL>(port), -1, payload);
          return;
        }
        if (!SerializeQueryResult(*f.result(), payload)) {
          PostDocument(static_cast<Dart_Port_DL>(port), -2, payload);
          return;
        }
        // seq 1 with an empty CBOR array is a query that matched nothing,
        // which is not the same as a failure — hence the distinct codes above.
        PostDocument(static_cast<Dart_Port_DL>(port), 1, payload);
      });
  return 0;
}

// The same query, watched. Returns a listener id for fdb_fs_unlisten, or a
// negative code.
FDB_EXPORT int64_t fdb_fs_query_listen(const char* collection_path,
                                      const uint8_t* spec, size_t spec_len,
                                      int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (collection_path == nullptr) return -2;

  Query query = g_firestore->Collection("_");
  const int rc = BuildQuery(collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  const int64_t id = g_next_listener++;
  auto seq = std::make_shared<int64_t>(0);
  g_listeners.emplace(
      id, query.AddSnapshotListener(
              [port, seq](const firebase::firestore::QuerySnapshot& snap,
                          firebase::firestore::Error error,
                          const std::string& message) {
                if (error == firebase::firestore::kErrorOk) {
                  std::vector<uint8_t> payload;
                  if (!SerializeQueryResult(snap, payload)) {
                    PostDocument(static_cast<Dart_Port_DL>(port), -2, payload);
                    return;
                  }
                  PostDocument(static_cast<Dart_Port_DL>(port), ++(*seq),
                               payload);
                  return;
                }
                // Carry the reason, as the document listener does: a listener
                // that stops silently is nearly always a rules problem, and an
                // empty result looks like data.
                const std::string text =
                    "error " + std::to_string(static_cast<int>(error)) +
                    (message.empty() ? "" : ": " + message);
                std::vector<uint8_t> err;
                CborEncoder measure;
                cbor_encoder_init(&measure, nullptr, 0, 0);
                cbor_encode_text_string(&measure, text.c_str(), text.size());
                err.resize(cbor_encoder_get_extra_bytes_needed(&measure));
                CborEncoder enc;
                cbor_encoder_init(&enc, err.data(), err.size(), 0);
                cbor_encode_text_string(&enc, text.c_str(), text.size());
                err.resize(cbor_encoder_get_buffer_size(&enc, err.data()));
                PostDocument(static_cast<Dart_Port_DL>(port), -1, err);
              }));
  return id;
}

FDB_EXPORT int64_t fdb_fs_delete(const char* doc_path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (doc_path == nullptr) return -2;
  g_firestore->Document(doc_path).Delete().OnCompletion(
      [port](const firebase::Future<void>& f) {
        PostOutcome(static_cast<Dart_Port_DL>(port), f.error() == 0, f.error(),
                    f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_get(const char* doc_path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (doc_path == nullptr) return -2;
  g_firestore->Document(doc_path).Get().OnCompletion(
      [port](const firebase::Future<DocumentSnapshot>& f) {
        std::vector<uint8_t> payload;
        if (f.error() != 0) {
          PostDocument(static_cast<Dart_Port_DL>(port), -1, payload);
          return;
        }
        const bool exists = f.result() != nullptr && f.result()->exists();
        if (exists && !fdb::SerializeDocument(f.result()->GetData(), payload)) {
          // Distinct from absence. An empty payload otherwise means the
          // document is not there, and a failed encode would be indis-
          // tinguishable from that — the caller would be told "missing" about a
          // document that exists.
          PostDocument(static_cast<Dart_Port_DL>(port), -2, payload);
          return;
        }
        // seq 1 with an empty payload: the document does not exist.
        PostDocument(static_cast<Dart_Port_DL>(port), 1, payload);
      });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_listen(const char* doc_path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_firestore == nullptr) return -1;
  if (doc_path == nullptr) return -2;

  const int64_t id = g_next_listener++;
  auto seq = std::make_shared<int64_t>(0);
  g_listeners.emplace(
      id, g_firestore->Document(doc_path).AddSnapshotListener(
              [port, seq](const DocumentSnapshot& snap,
                          firebase::firestore::Error error,
                          const std::string& message) {
                std::vector<uint8_t> payload;
                if (error == firebase::firestore::kErrorOk) {
                  if (snap.exists()) fdb::SerializeDocument(snap.GetData(), payload);
                  PostDocument(static_cast<Dart_Port_DL>(port), ++(*seq),
                               payload);
                  return;
                }
                // Carry the reason. A listener that stops with no explanation
                // is nearly always a rules problem, and the caller cannot tell
                // that from an empty document.
                const std::string text =
                    "error " + std::to_string(static_cast<int>(error)) +
                    (message.empty() ? "" : ": " + message);
                std::vector<uint8_t> err;
                CborEncoder measure;
                cbor_encoder_init(&measure, nullptr, 0, 0);
                cbor_encode_text_string(&measure, text.c_str(), text.size());
                err.resize(cbor_encoder_get_extra_bytes_needed(&measure));
                CborEncoder enc;
                cbor_encoder_init(&enc, err.data(), err.size(), 0);
                cbor_encode_text_string(&enc, text.c_str(), text.size());
                err.resize(cbor_encoder_get_buffer_size(&enc, err.data()));
                PostDocument(static_cast<Dart_Port_DL>(port), -1, err);
              }));
  return id;
}

FDB_EXPORT int64_t fdb_fs_unlisten(int64_t listener_id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_listeners.find(listener_id);
  if (it == g_listeners.end()) return -1;
  it->second.Remove();
  g_listeners.erase(it);
  return 0;
}

}  // extern "C"
