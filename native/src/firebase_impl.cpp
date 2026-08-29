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
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "dart_api_dl.h"
#include "cbor.h"
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
bool Serialize(const Variant& v, std::vector<uint8_t>& out) {
  CborEncoder measure;
  cbor_encoder_init(&measure, nullptr, 0, 0);
  EncodeVariant(v, &measure);
  const size_t needed = cbor_encoder_get_extra_bytes_needed(&measure);

  out.resize(needed);
  CborEncoder enc;
  cbor_encoder_init(&enc, out.data(), out.size(), 0);
  if (!EncodeVariant(v, &enc)) {
    out.clear();
    return false;
  }
  out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
  return true;
}

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
    if (!Serialize(snapshot.value(), payload)) {
      // Encoding cannot fail for what Database returns, but dropping the
      // snapshot beats posting a truncated one the decoder would reject.
      return;
    }
    PostSnapshot(port_, ++seq_, payload);
  }

  void OnCancelled(const Error& error, const char* message) override {
    // Carry the reason, not just the fact. A cancelled listener is nearly
    // always a rules or connectivity problem, and an error with no code or
    // message leaves the caller guessing at which.
    std::string text = "error " + std::to_string(static_cast<int>(error));
    if (message != nullptr && *message != '\0') {
      text += ": ";
      text += message;
    }
    std::vector<uint8_t> payload;
    if (!Serialize(Variant(text.c_str()), payload)) return;
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
                                const char* database_url) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_database != nullptr) {
    return 0;  // already initialized
  }

  firebase::AppOptions options;
  options.set_app_id(app_id);
  options.set_api_key(api_key);
  options.set_project_id(project_id);
  options.set_database_url(database_url);

  g_app = App::Create(options);
  if (g_app == nullptr) {
    return -1;
  }

  firebase::InitResult init_result;
  g_database = Database::GetInstance(g_app, &init_result);
  if (g_database == nullptr || init_result != firebase::kInitResultSuccess) {
    return -2;
  }
  return 0;
}

// The one App the module shares. Auth signs in on this instance, which is what
// makes Database see the credential — the SDK routes auth through the App.
FDB_EXPORT firebase::App* fdb_current_app(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_app;
}

FDB_EXPORT int64_t fdb_db_set_string(const char* path, const char* value) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_database == nullptr) {
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

FDB_EXPORT int64_t fdb_db_listen(const char* path, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_database == nullptr) {
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
