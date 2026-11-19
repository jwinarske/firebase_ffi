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

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
#include "fdb_cbor.h"
#include "firebase/app.h"
#include "firebase/firestore.h"
#include "firebase_bridge.h"

namespace {

using ::firebase::firestore::FieldPath;
using ::firebase::firestore::DocumentReference;
using ::firebase::firestore::DocumentSnapshot;
using ::firebase::firestore::FieldValue;
using ::firebase::firestore::Firestore;
using ::firebase::firestore::ListenerRegistration;
using ::firebase::firestore::MapFieldValue;
using ::firebase::firestore::Query;
using ::firebase::firestore::Transaction;
using ::firebase::firestore::SetOptions;

std::mutex g_mutex;

// The Firestore a reference being decoded on this thread belongs to. A
// reference value is a path until it is given one, and the decoder is many
// calls deep by then. Null outside a call that decodes for an app, where a
// reference does not decode.
thread_local Firestore* t_decoding = nullptr;

class DecodingFor {
 public:
  explicit DecodingFor(Firestore* firestore) : before_(t_decoding) {
    t_decoding = firestore;
  }
  ~DecodingFor() { t_decoding = before_; }
  DecodingFor(const DecodingFor&) = delete;
  DecodingFor& operator=(const DecodingFor&) = delete;

 private:
  Firestore* before_;
};

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
      // produced one, which would be a change in its behavior, not ours.
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

// Reads a CBOR float of any width.
//
// cbor_value_get_double is not a widening read: it answers only for a value
// the encoder wrote as a double. The encoder picks the narrowest form that
// holds the value exactly, so 1.5 goes out as a half and comes back through
// that call as whatever the union happened to hold -- writing 1.5 to a
// document stored 5.14e-315. The Realtime Database codec had the same bug;
// this is the same fix in Firestore's own decoder.
bool ReadCborDouble(CborValue* it, double* out) {
  switch (cbor_value_get_type(it)) {
    case CborDoubleType:
      return cbor_value_get_double(it, out) == CborNoError;
    case CborFloatType: {
      float f = 0;
      if (cbor_value_get_float(it, &f) != CborNoError) return false;
      *out = static_cast<double>(f);
      return true;
    }
    case CborHalfFloatType: {
      float f = 0;
      if (cbor_value_get_half_float_as_float(it, &f) != CborNoError) {
        return false;
      }
      *out = static_cast<double>(f);
      return true;
    }
    case CborIntegerType: {
      // A whole number the encoder wrote as an integer. Firestore keeps
      // integers and doubles apart, so this only arises where the ABI has
      // already said the value is a double: a geopoint's coordinates, or a
      // double increment of a whole number.
      int64_t i = 0;
      if (cbor_value_get_int64(it, &i) != CborNoError) return false;
      *out = static_cast<double>(i);
      return true;
    }
    default:
      return false;
  }
}

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
        if (!ReadCborDouble(&pair, &a) ||
            cbor_value_advance(&pair) != CborNoError ||
            !ReadCborDouble(&pair, &b) ||
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
      const bool known = t_decoding != nullptr;
      if (known) {
        *out =
            FieldValue::Reference(t_decoding->Document(std::string(path, len)));
      }
      std::free(path);
      return known;
    }
    // The payload is a one-element array rather than a bare number: Dart's
    // CBOR package drops tags when it normalizes an integer to a small int, so
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
        if (!ReadCborDouble(&elem, &by)) return false;
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
      if (!ReadCborDouble(it, &d)) return false;
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
// The spec names the document id "__name__", as the wire protocol does. The
// SDK spells it as a FieldPath rather than a name, and reading it as a dotted
// path would filter on a field nobody has.
bool IsDocumentId(const std::string& field) { return field == "__name__"; }

bool ApplyWhere(Query* q, const std::string& field, const std::string& op,
                const FieldValue& v) {
  if (IsDocumentId(field)) {
    const FieldPath path = FieldPath::DocumentId();
    if (op == "==") {
      *q = q->WhereEqualTo(path, v);
      return true;
    }
    if (op == "in") {
      if (!v.is_array()) return false;
      *q = q->WhereIn(path, v.array_value());
      return true;
    }
    // The rest are legal on __name__ in the protocol but are not what a
    // cursor needs, and binding them untested would be a guess.
    return false;
  }
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
  const Query::Direction direction = dir == "desc"
                                         ? Query::Direction::kDescending
                                         : Query::Direction::kAscending;
  *q = IsDocumentId(field) ? q->OrderBy(FieldPath::DocumentId(), direction)
                           : q->OrderBy(field, direction);
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

// What is waiting for an answer from one Firestore, by the port it is to
// arrive on. Deleting a Firestore drops what it had pending without
// completing it, so whatever is still here then is answered as failed. A
// completion takes its port before it posts, which is what keeps the two from
// both answering.
class Pending {
 public:
  // `outcome` is the shape the answer takes: [ok, code, message], or else a
  // snapshot buffer.
  void Add(int64_t port, bool outcome) {
    std::lock_guard<std::mutex> lock(m_);
    ports_[port] = outcome;
  }

  // True once for a port that was added.
  bool Take(int64_t port) {
    std::lock_guard<std::mutex> lock(m_);
    return ports_.erase(port) != 0;
  }

  std::unordered_map<int64_t, bool> TakeAll() {
    std::lock_guard<std::mutex> lock(m_);
    std::unordered_map<int64_t, bool> all;
    all.swap(ports_);
    return all;
  }

 private:
  std::mutex m_;
  std::unordered_map<int64_t, bool> ports_;
};

// One app's Firestore.
struct FirestoreState {
  Firestore* firestore = nullptr;
  // Set while the app is being deleted. Nothing new starts.
  bool closing = false;
  // Shared with the completions, which can outlive this.
  std::shared_ptr<Pending> pending = std::make_shared<Pending>();
};

// By app name, "" for the default app.
std::map<std::string, std::unique_ptr<FirestoreState>> g_states;

std::string AppKey(const char* app) { return app == nullptr ? "" : app; }

// The state to start on, or null when the app has no Firestore or is being
// deleted. Caller holds g_mutex.
FirestoreState* StateFor(const char* app) {
  const auto it = g_states.find(AppKey(app));
  if (it == g_states.end() || it->second->closing) return nullptr;
  return it->second.get();
}

// Listeners by id, each with the app it is on and the port it reports to. One
// sequence for every app, so an id names its listener without the app.
struct Listening {
  ListenerRegistration registration;
  std::string app;
  int64_t port = 0;
};
std::unordered_map<int64_t, Listening> g_listeners;
int64_t g_next_listener = 1;

// The reason as CBOR text, which is how a negative seq carries one.
std::vector<uint8_t> ReasonPayload(const std::string& text) {
  std::vector<uint8_t> payload;
  CborEncoder measure;
  cbor_encoder_init(&measure, nullptr, 0, 0);
  cbor_encode_text_string(&measure, text.c_str(), text.size());
  payload.resize(cbor_encoder_get_extra_bytes_needed(&measure));
  CborEncoder enc;
  cbor_encoder_init(&enc, payload.data(), payload.size(), 0);
  cbor_encode_text_string(&enc, text.c_str(), text.size());
  payload.resize(cbor_encoder_get_buffer_size(&enc, payload.data()));
  return payload;
}

// What a call that was pending, or a listener, is told when its app is
// deleted. kErrorCancelled, as the SDK numbers it.
constexpr int kAppDeletedCode = 1;
constexpr const char* kAppDeleted = "the app was deleted";

// What a transaction's update function answers with to end the transaction:
// the handler threw, or the app is being deleted. It has to be a code the SDK
// treats as final. It runs the function again after most failures, canceled
// and failed-precondition among them, and that would run the handler again.
constexpr firebase::firestore::Error kTxnFinal =
    firebase::firestore::kErrorNotFound;

enum class TxnRequest { kNone, kGet, kCommit, kAbort };

struct TxnState {
  std::mutex m;
  std::condition_variable cv;
  TxnRequest req = TxnRequest::kNone;
  std::string get_path;
  Dart_Port_DL get_port = 0;
  std::vector<uint8_t> writes;
  Transaction* txn = nullptr;
  int64_t attempt = 0;
  // The app it runs on, "" for the default one.
  std::string app;
  // Set when that app is being deleted. The SDK runs the update function
  // again after some failures, and an attempt that starts after this ends at
  // once rather than waiting on a handler that cannot answer.
  bool app_deleted = false;
};

// Transactions by id, one sequence for every app.
std::unordered_map<int64_t, std::shared_ptr<TxnState>> g_txns;
int64_t g_next_txn = 1;

// How long deleting an app waits for its transactions to end once they have
// been told to.
constexpr auto kReleaseWait = std::chrono::seconds(5);
constexpr auto kReleasePoll = std::chrono::milliseconds(10);

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
FDB_EXPORT int64_t fdb_fs_use_emulator(const char* app, const char* host,
                                       int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (host == nullptr || *host == '\0' || port <= 0 || port > 65535) return -2;
  firebase::firestore::Settings settings = fs->settings();
  settings.set_host(std::string(host) + ":" + std::to_string(port));
  settings.set_ssl_enabled(false);
  settings.set_persistence_enabled(false);
  fs->set_settings(settings);
  return 0;
}

FDB_EXPORT int64_t fdb_fs_init(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const std::string key = AppKey(app);
  const auto it = g_states.find(key);
  // -1 for one that is on its way out too: the app is as good as gone.
  if (it != g_states.end()) return it->second->closing ? -1 : 0;
  firebase::App* owner = fdb_app_named(app);
  if (owner == nullptr) return -1;
  firebase::InitResult result = firebase::kInitResultSuccess;
  Firestore* firestore = Firestore::GetInstance(owner, &result);
  if (firestore == nullptr || result != firebase::kInitResultSuccess) {
    return -2;
  }
  auto state = std::make_unique<FirestoreState>();
  state->firestore = firestore;
  g_states[key] = std::move(state);
  return 0;
}

// Deleting a Firestore waits for a transaction's update function to return,
// and ours is parked until Dart tells it what to do -- which Dart, blocked in
// the delete, never would. So each open transaction on the app is told to
// end, and the delete goes ahead once they have. One still inside a
// read that outlasts the wait leaves the Firestore as it was and answers -1,
// though the transactions stay ended. On 0 nothing new starts on the app
// until fdb_fs_release or fdb_fs_resume.
int64_t fdb_fs_quiesce(const char* app) {
  const std::string key = AppKey(app);
  std::vector<std::shared_ptr<TxnState>> open;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(key);
    if (it == g_states.end()) return 0;
    if (it->second->closing) return -1;
    it->second->closing = true;
    for (const auto& entry : g_txns) {
      if (entry.second->app == key) open.push_back(entry.second);
    }
  }
  for (const auto& txn : open) {
    {
      std::lock_guard<std::mutex> lock(txn->m);
      // A read that was asked for and not yet served is not going to be.
      if (txn->req == TxnRequest::kGet) {
        PostDocument(txn->get_port, -1, std::vector<uint8_t>());
      }
      txn->app_deleted = true;
      txn->req = TxnRequest::kAbort;
    }
    txn->cv.notify_one();
  }
  open.clear();

  const auto deadline = std::chrono::steady_clock::now() + kReleaseWait;
  for (;;) {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      const auto it = g_states.find(key);
      if (it == g_states.end()) return 0;
      if (std::none_of(g_txns.begin(), g_txns.end(), [&key](const auto& e) {
            return e.second->app == key;
          })) {
        return 0;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        it->second->closing = false;
        return -1;
      }
    }
    std::this_thread::sleep_for(kReleasePoll);
  }
}

void fdb_fs_resume(const char* app) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_states.find(AppKey(app));
  if (it != g_states.end()) it->second->closing = false;
}

// The Firestore is deleted outside the lock: doing it waits for callbacks
// that are running, and a callback may be waiting for the lock. What it had
// pending it drops, so those are answered here, after it has gone and no
// completion can still be on its way.
void fdb_fs_release(const char* app) {
  const std::string key = AppKey(app);
  std::unique_ptr<FirestoreState> state;
  std::vector<Listening> listening;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_states.find(key);
    if (it == g_states.end()) return;
    state = std::move(it->second);
    g_states.erase(it);
    for (auto l = g_listeners.begin(); l != g_listeners.end();) {
      if (l->second.app != key) {
        ++l;
        continue;
      }
      listening.push_back(std::move(l->second));
      l = g_listeners.erase(l);
    }
  }
  for (Listening& l : listening) l.registration.Remove();
  delete state->firestore;

  for (const auto& entry : state->pending->TakeAll()) {
    const auto port = static_cast<Dart_Port_DL>(entry.first);
    if (entry.second) {
      PostOutcome(port, false, kAppDeletedCode, kAppDeleted);
    } else {
      PostDocument(port, -1, std::vector<uint8_t>());
    }
  }
  const std::vector<uint8_t> reason = ReasonPayload(
      "error " + std::to_string(kAppDeletedCode) + ": " + kAppDeleted);
  for (const Listening& l : listening) {
    PostDocument(static_cast<Dart_Port_DL>(l.port), -1, reason);
  }
}

FDB_EXPORT int64_t fdb_fs_set(const char* app, const char* doc_path,
                              const uint8_t* cbor, size_t len, int32_t merge,
                              int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (doc_path == nullptr || cbor == nullptr) return -2;

  MapFieldValue data;
  {
    const DecodingFor decoding(fs);
    if (!fdb::ParseDocumentCbor(cbor, len, &data)) return -3;
  }

  auto pending = state->pending;
  pending->Add(port, true);
  fs->Document(doc_path)
      .Set(data, merge != 0 ? SetOptions::Merge() : SetOptions())
      .OnCompletion([port, pending](const firebase::Future<void>& f) {
        if (!pending->Take(port)) return;
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
// True when the spec asks for a collection group. Read before the query is
// created, because it decides which query that is -- the main loop below runs
// after the base exists and could not change it.
static bool SpecWantsCollectionGroup(const uint8_t* spec, size_t spec_len) {
  if (spec == nullptr || spec_len == 0) return false;
  CborParser parser;
  CborValue map;
  if (cbor_parser_init(spec, spec_len, 0, &parser, &map) != CborNoError ||
      !cbor_value_is_map(&map)) {
    return false;
  }
  CborValue entry;
  if (cbor_value_enter_container(&map, &entry) != CborNoError) return false;
  while (!cbor_value_at_end(&entry)) {
    std::string key;
    if (!ReadText(&entry, &key)) return false;
    if (key == "collectionGroup") {
      bool on = false;
      if (cbor_value_is_boolean(&entry) &&
          cbor_value_get_boolean(&entry, &on) == CborNoError) {
        return on;
      }
      return false;
    }
    if (cbor_value_advance(&entry) != CborNoError) return false;
  }
  return false;
}

static int BuildQuery(Firestore* fs, const char* collection_path,
                      const uint8_t* spec, size_t spec_len, Query* out) {
  // A cursor or a filter can hold a reference.
  const DecodingFor decoding(fs);
  // Building a query can throw: the SDK validates field paths and rejects a
  // malformed one with std::invalid_argument, which crossing this boundary
  // would abort the process rather than reach Dart. A caller's mistake must
  // come back as an error code, not as SIGABRT.
  try {
    Query query = SpecWantsCollectionGroup(spec, spec_len)
                      ? fs->CollectionGroup(collection_path)
                      : fs->Collection(collection_path);

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
        } else if (key == "collectionGroup") {
          // Consumed by the pre-pass; skipped here so it is not refused as an
          // unknown key.
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

// --- Transactions ----------------------------------------------------------
//
// The SDK runs the update function on its own thread and retries it, so the
// work has to happen there while the user's code lives in Dart. The lambda
// therefore parks on a condition variable and serves requests from Dart until
// told to commit:
//
//   Dart                            SDK thread (the lambda)
//   fdb_fs_txn_begin  ------------> starts, posts "attempt n", waits
//   fdb_fs_txn_get    ------------> wakes, Transaction::Get, posts result,
//   waits
//   ...                             (Dart buffers its writes meanwhile)
//   fdb_fs_txn_commit ------------> wakes, applies writes, returns
//
// Blocking that thread is safe and is the point: it is the SDK's worker, never
// Dart's isolate, which stays free to run the handler. A retry re-enters the
// lambda, which posts another attempt and the handler runs again -- which is
// why Dart listens to a stream of attempts rather than awaiting one result.
// extern "C++" around the anonymous namespace: this is inside the extern "C"
// block, where C language linkage suppresses mangling and an anonymous
// namespace alone does not make a name internal. Without it g_txns and
// g_next_txn are exported under those names, and the Realtime Database's
// transaction state picked the same one -- the link failed with "multiple
// definition" in the first build that compiled both files.
// (The state itself is defined with the rest, above the extern "C" block.)

// Applies the writes Dart buffered. They arrive as one CBOR array of
// [op, path, data?] rather than one call each: a write that reached the SDK
// before the handler finished could not be taken back if a later line threw.
// Templated over the writer: Transaction and WriteBatch have the same
// Set/Update/Delete surface, and two copies could drift on what an op means.
// extern "C++" because this block has C linkage and a template cannot.
extern "C++" template <typename Writer>
bool ApplyWrites(Firestore* fs, Writer& txn, const std::vector<uint8_t>& cbor) {
  if (cbor.empty()) return true;
  const DecodingFor decoding(fs);
  CborParser parser;
  CborValue array;
  if (cbor_parser_init(cbor.data(), cbor.size(), 0, &parser, &array) !=
          CborNoError ||
      !cbor_value_is_array(&array)) {
    return false;
  }
  CborValue entry;
  if (cbor_value_enter_container(&array, &entry) != CborNoError) return false;
  while (!cbor_value_at_end(&entry)) {
    CborValue item;
    if (!cbor_value_is_array(&entry) ||
        cbor_value_enter_container(&entry, &item) != CborNoError) {
      return false;
    }
    std::string op;
    std::string path;
    if (!ReadText(&item, &op) || !ReadText(&item, &path)) return false;

    if (op == "delete") {
      txn.Delete(fs->Document(path));
    } else if (op == "set" || op == "merge") {
      MapFieldValue data;
      if (!DecodeMap(&item, &data)) return false;
      txn.Set(fs->Document(path), data,
              op == "merge" ? firebase::firestore::SetOptions::Merge()
                            : firebase::firestore::SetOptions());
    } else if (op == "update") {
      MapFieldValue data;
      if (!DecodeMap(&item, &data)) return false;
      txn.Update(fs->Document(path), data);
    } else {
      return false;
    }
    if (cbor_value_advance(&entry) != CborNoError) return false;
  }
  return true;
}

FDB_EXPORT int64_t fdb_fs_query(const char* app, const char* collection_path,
                                const uint8_t* spec, size_t spec_len,
                                int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (collection_path == nullptr) return -2;

  Query query = fs->Collection("_");
  const int rc = BuildQuery(fs, collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  auto pending = state->pending;
  pending->Add(port, false);
  query.Get().OnCompletion(
      [port,
       pending](const firebase::Future<firebase::firestore::QuerySnapshot>& f) {
        if (!pending->Take(port)) return;
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
FDB_EXPORT int64_t fdb_fs_query_listen(const char* app,
                                       const char* collection_path,
                                       const uint8_t* spec, size_t spec_len,
                                       int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (collection_path == nullptr) return -2;

  Query query = fs->Collection("_");
  const int rc = BuildQuery(fs, collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  const int64_t id = g_next_listener++;
  auto seq = std::make_shared<int64_t>(0);
  g_listeners[id] =
      Listening{
          query.AddSnapshotListener(
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
              }),
          AppKey(app), port};
  return id;
}

// Counts what a query matches, without fetching it. Same spec as a read, so a
// filtered or grouped count needs nothing new.
// Sum and average, which need the SDK patch that exposes them. Without it
// Query has Count and nothing else, and the only way to add a column is to
// download every document.
//
// The result is a double even for a sum of integers. Firestore returns an
// integer there, and the SDK's value() widens it; a caller that wants an
// integer back can round one it knows is exact, which is better than this
// layer guessing which sums are safe to narrow.
static int64_t AggregateOne(const char* app, const char* collection_path,
                            const uint8_t* spec, size_t spec_len,
                            const char* field, int64_t port, bool average) {
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (collection_path == nullptr || field == nullptr || *field == '\0') {
    return -2;
  }

  Query query = fs->Collection("_");
  const int rc = BuildQuery(fs, collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  // Sum and Average parse the field path, and the SDK rejects a malformed one
  // by throwing. BuildQuery above already guards its own field paths for the
  // same reason: an exception crossing this boundary aborts the process
  // instead of reaching Dart.
  firebase::firestore::AggregateQuery aggregate;
  try {
    aggregate = average ? query.Average(field) : query.Sum(field);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "fdb_fs_aggregate: %s\n", e.what());
    return -4;
  }

  auto pending = state->pending;
  pending->Add(port, false);
  aggregate.Get(firebase::firestore::AggregateSource::kServer)
      .OnCompletion(
          [port, pending](const firebase::Future<
                          firebase::firestore::AggregateQuerySnapshot>& f) {
            if (!pending->Take(port)) return;
            std::vector<uint8_t> payload;
            if (f.error() != 0 || f.result() == nullptr) {
              PostDocument(static_cast<Dart_Port_DL>(port), -1, payload);
              return;
            }
            const double v = f.result()->value();
            CborEncoder measure;
            cbor_encoder_init(&measure, nullptr, 0, 0);
            cbor_encode_double(&measure, v);
            payload.resize(cbor_encoder_get_extra_bytes_needed(&measure));
            CborEncoder enc;
            cbor_encoder_init(&enc, payload.data(), payload.size(), 0);
            cbor_encode_double(&enc, v);
            payload.resize(cbor_encoder_get_buffer_size(&enc, payload.data()));
            PostDocument(static_cast<Dart_Port_DL>(port), 1, payload);
          });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_sum(const char* app, const char* collection_path,
                              const uint8_t* spec, size_t spec_len,
                              const char* field, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return AggregateOne(app, collection_path, spec, spec_len, field, port, false);
}

FDB_EXPORT int64_t fdb_fs_average(const char* app, const char* collection_path,
                                  const uint8_t* spec, size_t spec_len,
                                  const char* field, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return AggregateOne(app, collection_path, spec, spec_len, field, port, true);
}

FDB_EXPORT int64_t fdb_fs_count(const char* app, const char* collection_path,
                                const uint8_t* spec, size_t spec_len,
                                int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (collection_path == nullptr) return -2;

  Query query = fs->Collection("_");
  const int rc = BuildQuery(fs, collection_path, spec, spec_len, &query);
  if (rc != 0) return rc;

  auto pending = state->pending;
  pending->Add(port, false);
  query.Count()
      .Get(firebase::firestore::AggregateSource::kServer)
      .OnCompletion(
          [port, pending](const firebase::Future<
                          firebase::firestore::AggregateQuerySnapshot>& f) {
            if (!pending->Take(port)) return;
            std::vector<uint8_t> payload;
            if (f.error() != 0 || f.result() == nullptr) {
              PostDocument(static_cast<Dart_Port_DL>(port), -1, payload);
              return;
            }
            // The count travels as CBOR, like every other answer, rather than
            // as a bare integer in the header: one decode path, not two.
            const int64_t n = f.result()->count();
            CborEncoder measure;
            cbor_encoder_init(&measure, nullptr, 0, 0);
            cbor_encode_int(&measure, n);
            payload.resize(cbor_encoder_get_extra_bytes_needed(&measure));
            CborEncoder enc;
            cbor_encoder_init(&enc, payload.data(), payload.size(), 0);
            cbor_encode_int(&enc, n);
            payload.resize(cbor_encoder_get_buffer_size(&enc, payload.data()));
            PostDocument(static_cast<Dart_Port_DL>(port), 1, payload);
          });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_batch_commit(const char* app, const uint8_t* writes,
                                       size_t len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;

  firebase::firestore::WriteBatch batch = fs->batch();
  if (!ApplyWrites(fs, batch, std::vector<uint8_t>(writes, writes + len))) {
    return -3;
  }
  auto pending = state->pending;
  pending->Add(port, true);
  batch.Commit().OnCompletion([port, pending](const firebase::Future<void>& f) {
    if (!pending->Take(port)) return;
    fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                     f.error_message() == nullptr ? "" : f.error_message());
  });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_txn_begin(const char* app, int64_t port) {
  std::shared_ptr<TxnState> state;
  Firestore* fs = nullptr;
  int64_t id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    FirestoreState* on = StateFor(app);
    if (on == nullptr) return -1;
    fs = on->firestore;
    state = std::make_shared<TxnState>();
    state->app = AppKey(app);
    id = g_next_txn++;
    g_txns.emplace(id, state);
  }
  const auto dart_port = static_cast<Dart_Port_DL>(port);

  // `fs` outlives the function it is captured by: the app is not deleted
  // while a transaction on it is open.
  fs->RunTransaction([state, dart_port, fs](
                         Transaction& txn,
                         std::string& error) -> firebase::firestore::Error {
      std::unique_lock<std::mutex> lock(state->m);
      if (state->app_deleted) {
        error = kAppDeleted;
        return kTxnFinal;
      }
      state->txn = &txn;
      ++state->attempt;

      // Tell Dart to run the handler. A retry lands here again with a higher
      // attempt number, which is what makes the handler run a second time.
      PostDocument(dart_port, state->attempt, std::vector<uint8_t>());

      for (;;) {
        state->cv.wait(lock, [&] { return state->req != TxnRequest::kNone; });
        const TxnRequest req = state->req;

        if (req == TxnRequest::kGet) {
          const std::string path = state->get_path;
          const Dart_Port_DL reply = state->get_port;
          state->req = TxnRequest::kNone;
          // Unlocked across the read: it goes to the network, and holding the
          // lock would stop Dart queueing anything while it runs.
          lock.unlock();
          firebase::firestore::Error code = firebase::firestore::kErrorOk;
          std::string message;
          const DocumentSnapshot snap =
              txn.Get(fs->Document(path), &code, &message);
          std::vector<uint8_t> payload;
          if (code != firebase::firestore::kErrorOk) {
            PostDocument(reply, -1, payload);
          } else {
            if (snap.exists()) fdb::SerializeDocument(snap.GetData(), payload);
            PostDocument(reply, 1, payload);
          }
          lock.lock();
          continue;
        }

        if (req == TxnRequest::kAbort) {
          state->req = TxnRequest::kNone;
          if (state->app_deleted) {
            error = kAppDeleted;
            return kTxnFinal;
          }
          error = "transaction aborted by the handler";
          return kTxnFinal;
        }

        // kCommit: apply what Dart buffered, then let the SDK commit.
        std::vector<uint8_t> writes = std::move(state->writes);
        state->writes.clear();
        state->req = TxnRequest::kNone;
        lock.unlock();
        const bool ok = ApplyWrites(fs, txn, writes);
        lock.lock();
        if (!ok) {
          error = "a buffered write could not be decoded";
          return firebase::firestore::kErrorInvalidArgument;
        }
        return firebase::firestore::kErrorOk;
      }
    }).OnCompletion([dart_port, id](const firebase::Future<void>& f) {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_txns.erase(id);
    }
    // seq 0 is the terminal event: the transaction finished, and the payload
    // carries the reason when it failed.
    if (f.error() == 0) {
      PostDocument(dart_port, 0, std::vector<uint8_t>());
      return;
    }
    const std::string text =
        "error " + std::to_string(f.error()) +
        (f.error_message() == nullptr ? "" : std::string(": ") + f.error_message());
    std::vector<uint8_t> err;
    CborEncoder measure;
    cbor_encoder_init(&measure, nullptr, 0, 0);
    cbor_encode_text_string(&measure, text.c_str(), text.size());
    err.resize(cbor_encoder_get_extra_bytes_needed(&measure));
    CborEncoder enc;
    cbor_encoder_init(&enc, err.data(), err.size(), 0);
    cbor_encode_text_string(&enc, text.c_str(), text.size());
    err.resize(cbor_encoder_get_buffer_size(&enc, err.data()));
    PostDocument(dart_port, -1, err);
  });
  return id;
}

// Caller-side helpers. Each wakes the parked lambda; none of them touch the
// Transaction directly, because it belongs to the SDK's thread.
static std::shared_ptr<TxnState> TxnFor(int64_t id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_txns.find(id);
  return it == g_txns.end() ? nullptr : it->second;
}

FDB_EXPORT int64_t fdb_fs_txn_get(int64_t txn_id, const char* doc_path,
                                 int64_t port) {
  auto state = TxnFor(txn_id);
  if (state == nullptr) return -1;
  if (doc_path == nullptr) return -2;
  {
    std::lock_guard<std::mutex> lock(state->m);
    state->get_path = doc_path;
    state->get_port = static_cast<Dart_Port_DL>(port);
    state->req = TxnRequest::kGet;
  }
  state->cv.notify_one();
  return 0;
}

FDB_EXPORT int64_t fdb_fs_txn_commit(int64_t txn_id, const uint8_t* writes,
                                    size_t len) {
  auto state = TxnFor(txn_id);
  if (state == nullptr) return -1;
  {
    std::lock_guard<std::mutex> lock(state->m);
    state->writes.assign(writes, writes + len);
    state->req = TxnRequest::kCommit;
  }
  state->cv.notify_one();
  return 0;
}

FDB_EXPORT int64_t fdb_fs_txn_abort(int64_t txn_id) {
  auto state = TxnFor(txn_id);
  if (state == nullptr) return -1;
  {
    std::lock_guard<std::mutex> lock(state->m);
    state->req = TxnRequest::kAbort;
  }
  state->cv.notify_one();
  return 0;
}

FDB_EXPORT int64_t fdb_fs_delete(const char* app, const char* doc_path,
                                 int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (doc_path == nullptr) return -2;
  auto pending = state->pending;
  pending->Add(port, true);
  fs->Document(doc_path).Delete().OnCompletion(
      [port, pending](const firebase::Future<void>& f) {
        if (!pending->Take(port)) return;
        PostOutcome(static_cast<Dart_Port_DL>(port), f.error() == 0, f.error(),
                    f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_fs_get(const char* app, const char* doc_path,
                              int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (doc_path == nullptr) return -2;
  auto pending = state->pending;
  pending->Add(port, false);
  fs->Document(doc_path).Get().OnCompletion(
      [port, pending](const firebase::Future<DocumentSnapshot>& f) {
        if (!pending->Take(port)) return;
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

FDB_EXPORT int64_t fdb_fs_listen(const char* app, const char* doc_path,
                                 int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  FirestoreState* state = StateFor(app);
  if (state == nullptr) return -1;
  Firestore* fs = state->firestore;
  if (doc_path == nullptr) return -2;

  const int64_t id = g_next_listener++;
  auto seq = std::make_shared<int64_t>(0);
  g_listeners[id] =
      Listening{
          fs->Document(doc_path).AddSnapshotListener(
              [port, seq](const DocumentSnapshot& snap,
                          firebase::firestore::Error error,
                          const std::string& message) {
                std::vector<uint8_t> payload;
                if (error == firebase::firestore::kErrorOk) {
                  if (snap.exists())
                    fdb::SerializeDocument(snap.GetData(), payload);
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
              }),
          AppKey(app), port};
  return id;
}

FDB_EXPORT int64_t fdb_fs_unlisten(int64_t listener_id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_listeners.find(listener_id);
  if (it == g_listeners.end()) return -1;
  it->second.registration.Remove();
  g_listeners.erase(it);
  return 0;
}

}  // extern "C"
