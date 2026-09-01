// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// v2 — the real Realtime Database behind the same C ABI.
//
// Compiled only when the SDK was found (FDB_HAVE_FIREBASE). The transport half
// in bridge.cpp is unchanged and still measurable; this adds the calls that
// make fdb_set and fdb_listen talk to Firebase instead of to a synthetic
// emitter.
//
// Two things shape the design:
//
//  * A DataSnapshot is only valid inside its callback, so the Variant must be
//    serialized there. That copy is unavoidable in any transport, which is why
//    the benchmark treats it as the floor rather than as overhead.
//
//  * ValueListener callbacks arrive on SDK worker threads, and
//    Dart_PostCObject_DL is safe from any thread. So the snapshot goes straight
//    to the port from the SDK's own thread — no marshal to a platform thread,
//    which is the structural advantage over a method channel.

#include <cstdlib>
#include <cstring>
#include <map>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "dart_api_dl.h"
#include "cbor.h"
#include "fdb_cbor.h"
#include "firebase_bridge.h"

#include "firebase/app.h"
#include "firebase/database.h"
#include "firebase/database/listener.h"
#include "firebase/variant.h"

namespace {

using ::firebase::App;
using ::firebase::Variant;
using ::firebase::database::Database;
using ::firebase::database::DataSnapshot;
using ::firebase::database::Error;
using ::firebase::database::ValueListener;

App* g_app = nullptr;
Database* g_database = nullptr;
std::mutex g_mutex;

// ── Variant → a flat tagged buffer ──────────────────────────────────────────
//
// One pass, one allocation, depth-first. Every node is a tag byte followed by
// its payload; containers write their element count and then their children
// inline. Dart can walk this without allocating per node, which is the point:
// the alternative is building an EncodableValue tree that a codec then
// re-serializes.
// firebase::Variant serialized as CBOR (RFC 8949).
//
// A standard format rather than a private one: the Dart side decodes with a
// conformant package, so a malformed message is rejected by an implementation
// this project did not write, and the two halves cannot drift apart in the way
// a hand-synced tag table can.
//
// Sizing pass then encode: CborNoMoreMemory tells us the buffer was short, so
// the first pass measures against a null buffer and the second fills one.
bool EncodeVariant(const Variant& v, CborEncoder* enc);

bool EncodeVariant(const Variant& v, CborEncoder* enc) {
  if (v.is_null()) return cbor_encode_null(enc) == CborNoError;
  if (v.is_bool()) return cbor_encode_boolean(enc, v.bool_value()) == CborNoError;
  if (v.is_int64()) return cbor_encode_int(enc, v.int64_value()) == CborNoError;
  if (v.is_double()) return cbor_encode_double(enc, v.double_value()) == CborNoError;
  if (v.is_string()) {
    const char* s = v.string_value();
    return cbor_encode_text_string(enc, s ? s : "", s ? std::strlen(s) : 0) ==
           CborNoError;
  }
  if (v.is_blob()) {
    // Byte string, distinct from text — the previous encoding had no way to say
    // this and wrote null instead.
    return cbor_encode_byte_string(enc, v.blob_data(),
                                   static_cast<size_t>(v.blob_size())) ==
           CborNoError;
  }
  if (v.is_vector()) {
    const auto& items = v.vector();
    CborEncoder array;
    if (cbor_encoder_create_array(enc, &array, items.size()) != CborNoError) {
      return false;
    }
    for (const auto& item : items) {
      if (!EncodeVariant(item, &array)) return false;
    }
    return cbor_encoder_close_container(enc, &array) == CborNoError;
  }
  if (v.is_map()) {
    const auto& entries = v.map();
    CborEncoder map;
    if (cbor_encoder_create_map(enc, &map, entries.size()) != CborNoError) {
      return false;
    }
    for (const auto& entry : entries) {
      // Database keys are strings. Anything else is a response this build does
      // not understand; encoding it as null keeps the map well-formed and the
      // pair count honest.
      if (entry.first.is_string()) {
        const char* k = entry.first.string_value();
        if (cbor_encode_text_string(&map, k ? k : "", k ? std::strlen(k) : 0) !=
            CborNoError) {
          return false;
        }
      } else if (cbor_encode_null(&map) != CborNoError) {
        return false;
      }
      if (!EncodeVariant(entry.second, &map)) return false;
    }
    return cbor_encoder_close_container(enc, &map) == CborNoError;
  }
  return cbor_encode_null(enc) == CborNoError;
}

// Encodes [v] into [out]. Measures first, so the buffer is exact.
}  // namespace

namespace fdb {

bool SerializeVariant(const Variant& v, std::vector<uint8_t>& out) {
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
    if (EncodeVariant(v, &enc)) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    cap *= 2;
  }
  out.clear();
  return false;
}


bool DecodeVariant(CborValue* it, Variant* out);

bool DecodeVariantMap(CborValue* it, Variant* out) {
  CborValue entry;
  if (cbor_value_enter_container(it, &entry) != CborNoError) return false;
  std::map<Variant, Variant> map;
  while (!cbor_value_at_end(&entry)) {
    Variant key;
    Variant value;
    if (!DecodeVariant(&entry, &key)) return false;
    if (!DecodeVariant(&entry, &value)) return false;
    map.emplace(key, value);
  }
  if (cbor_value_leave_container(it, &entry) != CborNoError) return false;
  *out = Variant(map);
  return true;
}

bool DecodeVariantArray(CborValue* it, Variant* out) {
  CborValue elem;
  if (cbor_value_enter_container(it, &elem) != CborNoError) return false;
  std::vector<Variant> list;
  while (!cbor_value_at_end(&elem)) {
    Variant item;
    if (!DecodeVariant(&elem, &item)) return false;
    list.push_back(item);
  }
  if (cbor_value_leave_container(it, &elem) != CborNoError) return false;
  *out = Variant(list);
  return true;
}

bool DecodeVariant(CborValue* it, Variant* out) {
  switch (cbor_value_get_type(it)) {
    case CborNullType:
    case CborUndefinedType:
      *out = Variant::Null();
      return cbor_value_advance(it) == CborNoError;
    case CborBooleanType: {
      bool b = false;
      if (cbor_value_get_boolean(it, &b) != CborNoError) return false;
      *out = Variant::FromBool(b);
      return cbor_value_advance(it) == CborNoError;
    }
    case CborIntegerType: {
      int64_t n = 0;
      if (cbor_value_get_int64(it, &n) != CborNoError) return false;
      *out = Variant::FromInt64(n);
      return cbor_value_advance(it) == CborNoError;
    }
    // Each width has its own accessor. cbor_value_get_double on a float or a
    // half is not a widening read -- the encoder picks the narrowest form that
    // holds the value exactly, so 1.5 arrives as a half and came back 0.0.
    case CborDoubleType: {
      double d = 0;
      if (cbor_value_get_double(it, &d) != CborNoError) return false;
      *out = Variant::FromDouble(d);
      return cbor_value_advance(it) == CborNoError;
    }
    case CborFloatType: {
      float f = 0;
      if (cbor_value_get_float(it, &f) != CborNoError) return false;
      *out = Variant::FromDouble(static_cast<double>(f));
      return cbor_value_advance(it) == CborNoError;
    }
    case CborHalfFloatType: {
      float f = 0;
      if (cbor_value_get_half_float_as_float(it, &f) != CborNoError) {
        return false;
      }
      *out = Variant::FromDouble(static_cast<double>(f));
      return cbor_value_advance(it) == CborNoError;
    }
    case CborTextStringType: {
      char* buf = nullptr;
      size_t len = 0;
      if (cbor_value_dup_text_string(it, &buf, &len, it) != CborNoError) {
        return false;
      }
      // FromMutableString copies; the SDK holds it after this returns and the
      // buffer here does not outlive the call.
      *out = Variant::FromMutableString(std::string(buf, len));
      std::free(buf);
      return true;
    }
    case CborByteStringType: {
      uint8_t* buf = nullptr;
      size_t len = 0;
      if (cbor_value_dup_byte_string(it, &buf, &len, it) != CborNoError) {
        return false;
      }
      *out = Variant::FromMutableBlob(buf, len);
      std::free(buf);
      return true;
    }
    case CborArrayType:
      return DecodeVariantArray(it, out);
    case CborMapType:
      return DecodeVariantMap(it, out);
    default:
      return false;
  }
}

bool ParseVariant(const uint8_t* cbor, size_t len, Variant* out) {
  CborParser parser;
  CborValue it;
  if (cbor_parser_init(cbor, len, 0, &parser, &it) != CborNoError) {
    return false;
  }
  return DecodeVariant(&it, out);
}

bool ParseVariantMap(const uint8_t* cbor, size_t len,
                     std::map<std::string, Variant>* out) {
  Variant v;
  if (!ParseVariant(cbor, len, &v) || !v.is_map()) return false;
  for (const auto& kv : v.map()) {
    // Keys are strings here even though a Variant map allows more: every
    // caller of this is a string-keyed API, and silently stringifying a
    // non-string key would invent a key nobody wrote.
    if (!kv.first.is_string()) return false;
    out->emplace(kv.first.string_value(), kv.second);
  }
  return true;
}

bool SerializeVariantMap(const std::map<std::string, Variant>& m,
                         std::vector<uint8_t>& out) {
  std::map<Variant, Variant> as_variant;
  for (const auto& kv : m) {
    as_variant.emplace(Variant::FromMutableString(kv.first), kv.second);
  }
  return SerializeVariant(Variant(as_variant), out);
}

}  // namespace fdb

namespace {

// Frees a posted buffer once the Dart GC is done with it. Registered as the
// finalizer for every kExternalTypedData message below, so ownership passes to
// the VM and nothing here may touch the buffer afterwards.
void SnapshotFinalizer(void* /*isolate_callback_data*/, void* peer) {
  std::free(peer);
}

void PostSnapshot(Dart_Port_DL port, int64_t seq,
                  const std::vector<uint8_t>& payload) {
  const size_t total = sizeof(FdbSnapshotHeader) + payload.size();
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) {
    return;
  }

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
  obj.value.as_external_typed_data.callback = SnapshotFinalizer;
  Dart_PostCObject_DL(port, &obj);
}

// Serializes on the SDK's thread and posts from it. The listener outlives the
// query by construction: it is owned by the map below and only destroyed by
// fdb_unlisten, after RemoveValueListener has returned.
class PortValueListener : public ValueListener {
 public:
  PortValueListener(Dart_Port_DL port, firebase::database::Query query)
      : port_(port), query_(std::move(query)) {}

  void OnValueChanged(const DataSnapshot& snapshot) override {
    std::vector<uint8_t> payload;
    if (!fdb::SerializeVariant(snapshot.value(), payload)) {
      // Encoding cannot fail for what Database returns, but dropping the
      // snapshot beats posting a truncated one the decoder would reject.
      return;
    }
    PostSnapshot(port_, ++seq_, payload);
  }

  void OnCancelled(const Error& error, const char* message) override {
    // Carry the reason, not just the fact. A canceled listener is nearly
    // always a rules or connectivity problem, and an error with no code or
    // message leaves the caller guessing at which.
    std::string text = "error " + std::to_string(static_cast<int>(error));
    if (message != nullptr && *message != '\0') {
      text += ": ";
      text += message;
    }
    std::vector<uint8_t> payload;
    if (!fdb::SerializeVariant(Variant(text.c_str()), payload)) return;
    PostSnapshot(port_, -1, payload);
  }

  firebase::database::Query& query() { return query_; }

 private:
  Dart_Port_DL port_;
  firebase::database::Query query_;
  int64_t seq_ = 0;
};

std::map<int64_t, std::unique_ptr<PortValueListener>> g_listeners;

}  // namespace

extern "C" {

FDB_EXPORT int64_t fdb_app_init(const char* app_id, const char* api_key,
                                const char* project_id,
                                const char* database_url,
                                const char* storage_bucket) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_app != nullptr) {
    return 0;  // already initialized
  }

  firebase::AppOptions options;
  options.set_app_id(app_id);
  options.set_api_key(api_key);
  options.set_project_id(project_id);
  // Optional, like the bucket: an app that binds only Auth or Storage has no
  // database to name, and an empty url is not the same as a default one.
  if (database_url != nullptr && *database_url != '\0') {
    options.set_database_url(database_url);
  }
  // Storage derives its bucket from the app, and there is no second chance to
  // supply one: Storage::GetInstance(app) with no bucket set fails the first
  // operation with an unknown error rather than at init. Optional, because a
  // build that binds no Storage has nothing to name.
  if (storage_bucket != nullptr && *storage_bucket != '\0') {
    options.set_storage_bucket(storage_bucket);
  }

  g_app = App::Create(options);
  if (g_app == nullptr) {
    return -1;
  }
  // The Database is created on first use, not here. Standing one up for an app
  // that never touches it costs a connection the app did not ask for, and a
  // Database that cannot reach its backend does not fail quietly -- it was
  // enough to stall an unrelated anonymous sign-in, because the SDK's
  // scheduler is shared.
  return 0;
}

// Caller holds g_mutex.
static Database* EnsureDatabase() {
  if (g_database != nullptr) return g_database;
  if (g_app == nullptr) return nullptr;
  firebase::InitResult init_result;
  g_database = Database::GetInstance(g_app, &init_result);
  if (init_result != firebase::kInitResultSuccess) {
    g_database = nullptr;
  }
  return g_database;
}

// The one App the module shares. Auth signs in on this instance, which is what
// makes Database see the credential — the SDK routes auth through the App.
FDB_EXPORT firebase::App* fdb_current_app(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_app;
}

FDB_EXPORT int64_t fdb_db_set_string(const char* path, const char* value) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) {
    return -1;
  }
  // MutableString, not Variant(const char*): that constructor makes a *static*
  // string variant which stores the pointer without copying, and SetValue is
  // asynchronous — the caller is free to release the buffer as soon as this
  // returns, so a static string here is a use-after-free that writes garbage
  // to the database rather than failing.
  g_database->GetReference(path).SetValue(
      Variant::MutableStringFromStaticString(value));
  return 0;
}

// The value operations, taking a Variant rather than a string.
//
// fdb_db_set_string stays: it is what the transport benchmark measures, and it
// is fire-and-forget by design there. Everything below answers on a port,
// because an app that cannot tell whether a write landed has no way to retry.

FDB_EXPORT int64_t fdb_db_set(const char* path, const uint8_t* cbor,
                              size_t len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  g_database->GetReference(path).SetValue(value).OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// UpdateChildren, which writes the named children and leaves the rest alone.
// Not the same as SetValue with a partial map, which would delete everything
// not mentioned.
FDB_EXPORT int64_t fdb_db_update(const char* path, const uint8_t* cbor,
                                 size_t len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  // The SDK asserts on a non-map here rather than returning an error, so it is
  // refused before it gets there.
  if (!value.is_map()) return -4;
  g_database->GetReference(path).UpdateChildren(value).OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_db_remove(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  g_database->GetReference(path).RemoveValue().OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// PushChild generates its key locally -- no request -- so the key is returned
// rather than posted. The caller writes to it with fdb_db_set.
FDB_EXPORT int64_t fdb_db_push(const char* path, char* out, size_t cap) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr || out == nullptr || cap == 0) return -2;
  const std::string key = g_database->GetReference(path).PushChild().key_string();
  if (key.empty()) return -3;
  if (key.size() + 1 > cap) return -4;
  std::memcpy(out, key.c_str(), key.size() + 1);
  return static_cast<int64_t>(key.size());
}

FDB_EXPORT int64_t fdb_db_listen(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) {
    return -1;
  }
  static int64_t next = 1;
  const int64_t handle = next++;
  auto listener = std::make_unique<PortValueListener>(
      static_cast<Dart_Port_DL>(port), g_database->GetReference(path));
  listener->query().AddValueListener(listener.get());
  g_listeners.emplace(handle, std::move(listener));
  return handle;
}

FDB_EXPORT void fdb_db_unlisten(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto it = g_listeners.find(handle);
  if (it == g_listeners.end()) {
    return;
  }
  // Remove before destroying: the SDK holds a raw pointer to the listener.
  it->second->query().RemoveValueListener(it->second.get());
  g_listeners.erase(it);
}

}  // extern "C"
