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

#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "cbor.h"
#include "dart_api_dl.h"
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

bool SerializeMap(const MapFieldValue& m, std::vector<uint8_t>& out) {
  CborEncoder measure;
  cbor_encoder_init(&measure, nullptr, 0, 0);
  EncodeMap(m, &measure);
  out.resize(cbor_encoder_get_extra_bytes_needed(&measure));

  CborEncoder enc;
  cbor_encoder_init(&enc, out.data(), out.size(), 0);
  if (!EncodeMap(m, &enc)) {
    out.clear();
    return false;
  }
  out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
  return true;
}

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
bool ParseDocument(const uint8_t* cbor, size_t len, MapFieldValue* out) {
  CborParser parser;
  CborValue it;
  if (cbor_parser_init(cbor, len, 0, &parser, &it) != CborNoError) return false;
  if (!cbor_value_is_map(&it)) return false;
  return DecodeMap(&it, out);
}

}  // namespace

extern "C" {

FDB_EXPORT int32_t fdb_have_firestore(void) { return 1; }

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
  if (!ParseDocument(cbor, len, &data)) return -3;

  g_firestore->Document(doc_path)
      .Set(data, merge != 0 ? SetOptions::Merge() : SetOptions())
      .OnCompletion([port](const firebase::Future<void>& f) {
        PostOutcome(static_cast<Dart_Port_DL>(port), f.error() == 0, f.error(),
                    f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
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
        if (f.error() == 0 && f.result() != nullptr && f.result()->exists()) {
          SerializeMap(f.result()->GetData(), payload);
        }
        // seq -1 reports an error, matching the Database convention; an empty
        // payload on seq 1 means the document is absent.
        PostDocument(static_cast<Dart_Port_DL>(port),
                     f.error() == 0 ? 1 : -1, payload);
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
                  if (snap.exists()) SerializeMap(snap.GetData(), payload);
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
