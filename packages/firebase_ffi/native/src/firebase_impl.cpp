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
#include <condition_variable>
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
#include "firebase/database/disconnection.h"
#include "firebase/database/mutable_data.h"
#include "firebase/database/transaction.h"
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


// Encodes a snapshot's child keys, in the order the query produced them, as
// nested [key, sub-order | null] pairs. Empty for a leaf.
bool EncodeOrder(const firebase::database::DataSnapshot& snap,
                 CborEncoder* enc) {
  const std::vector<firebase::database::DataSnapshot> kids = snap.children();
  CborEncoder array;
  if (cbor_encoder_create_array(enc, &array, kids.size()) != CborNoError) {
    return false;
  }
  for (const auto& child : kids) {
    CborEncoder entry;
    if (cbor_encoder_create_array(&array, &entry, 2) != CborNoError) {
      return false;
    }
    const std::string key = child.key_string();
    if (cbor_encode_text_stringz(&entry, key.c_str()) != CborNoError) {
      return false;
    }
    if (child.has_children()) {
      if (!EncodeOrder(child, &entry)) return false;
    } else if (cbor_encode_null(&entry) != CborNoError) {
      return false;
    }
    if (cbor_encoder_close_container(&array, &entry) != CborNoError) {
      return false;
    }
  }
  return cbor_encoder_close_container(enc, &array) == CborNoError;
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

bool SerializeOrder(const firebase::database::DataSnapshot& snap,
                    std::vector<uint8_t>& out) {
  // Same grow-and-retry as SerializeVariant, for the same reason.
  size_t cap = 256;
  for (int attempt = 0; attempt < 16; ++attempt) {
    out.assign(cap, 0);
    CborEncoder enc;
    cbor_encoder_init(&enc, out.data(), cap, 0);
    if (EncodeOrder(snap, &enc)) {
      out.resize(cbor_encoder_get_buffer_size(&enc, out.data()));
      return true;
    }
    cap *= 2;
  }
  out.clear();
  return false;
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
                  const std::vector<uint8_t>& payload,
                  const std::vector<uint8_t>& order = {}) {
  const size_t total =
      sizeof(FdbSnapshotHeader) + payload.size() + order.size();
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) {
    return;
  }

  FdbSnapshotHeader header{};
  header.magic = 0xFDB50000u;
  header.version = 1u;
  header.seq = seq;
  header.value_len = static_cast<uint32_t>(payload.size());
  header.order_len = static_cast<uint32_t>(order.size());
  header.posted_ns = fdb_now_ns();
  std::memcpy(buf, &header, sizeof(header));
  if (!payload.empty()) {
    std::memcpy(buf + sizeof(header), payload.data(), payload.size());
  }
  if (!order.empty()) {
    std::memcpy(buf + sizeof(header) + payload.size(), order.data(),
                order.size());
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
    // The value is a Variant map, which the SDK sorts by key. A query's
    // ordering lives only in children(), so it travels beside the value.
    std::vector<uint8_t> order;
    if (!fdb::SerializeOrder(snapshot, order)) order.clear();
    PostSnapshot(port_, ++seq_, payload, order);
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

// Child events, which a value listener cannot express: it reports the whole
// node on every change, so a caller cannot tell which child moved, or see a
// removal at all once the node is gone.
//
// Each event is a CBOR map: {"type", "key", "prev", "value"}. `prev` is the
// key of the sibling before this one in the query's ordering, and is null for
// the first -- that is what lets a caller keep an ordered list without
// re-reading the node.
class PortChildListener : public firebase::database::ChildListener {
 public:
  PortChildListener(Dart_Port_DL port, firebase::database::Query query)
      : port_(port), query_(std::move(query)) {}

  void OnChildAdded(const DataSnapshot& snapshot,
                    const char* previous) override {
    Post(0, snapshot, previous);
  }
  void OnChildChanged(const DataSnapshot& snapshot,
                      const char* previous) override {
    Post(1, snapshot, previous);
  }
  void OnChildMoved(const DataSnapshot& snapshot,
                    const char* previous) override {
    Post(2, snapshot, previous);
  }
  void OnChildRemoved(const DataSnapshot& snapshot) override {
    Post(3, snapshot, nullptr);
  }

  void OnCancelled(const Error& error, const char* message) override {
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
  void Post(int64_t type, const DataSnapshot& snapshot, const char* previous) {
    std::map<std::string, Variant> event;
    event["type"] = Variant(type);
    // Copies, rather than Variant::MutableStringFromStaticString, which
    // stores the pointer without owning it. These are serialized inside this
    // call so an alias would survive, but the two constructors differ by a
    // name alone and the aliasing one has already cost this project a bug.
    event["key"] =
        Variant(std::string(snapshot.key() == nullptr ? "" : snapshot.key()));
    // The SDK says "no predecessor" with an empty string, not a null pointer.
    // Passing that through gives Dart a child whose previous sibling is a key
    // that cannot exist, rather than one that is first.
    event["prev"] = (previous == nullptr || *previous == '\0')
                        ? Variant::Null()
                        : Variant(std::string(previous));
    event["value"] = snapshot.value();

    std::vector<uint8_t> payload;
    if (!fdb::SerializeVariantMap(event, payload)) return;
    PostSnapshot(port_, ++seq_, payload);
  }

  Dart_Port_DL port_;
  firebase::database::Query query_;
  int64_t seq_ = 0;
};

std::map<int64_t, std::unique_ptr<PortChildListener>> g_child_listeners;

// Shared by fdb_db_listen and fdb_db_query_listen, which put their listeners
// in the same map: two counters would hand out the same handle twice, and
// emplace drops the second rather than replacing it, so a listener would go
// quiet with nothing to say it had.
int64_t g_next_value_handle = 1;
// Child handles start far below the error codes. Numbering them -1, -2, -3
// would make the first three listeners indistinguishable from the -1, -2 and
// -3 this ABI returns for a failure, and the caller would treat a working
// listener as a refusal.
int64_t g_next_child_handle = 1000;

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

// extern "C++" around the anonymous namespace: these are inside the extern
// "C" block, where C language linkage suppresses mangling and an anonymous
// namespace alone does not make a name internal. Without this the helpers are
// exported under their plain names.
extern "C++" {
namespace {

// Builds a Query from a CBOR spec.
//
//   {"orderBy": "child"|"key"|"value"|"priority",
//    "orderByPath": "a/b",                      -- with orderBy "child"
//    "startAt": v, "startAtKey": "k",
//    "endAt":   v, "endAtKey":   "k",
//    "equalTo": v, "equalToKey": "k",
//    "limitToFirst": n, "limitToLast": n}
//
// A key this does not understand is refused rather than ignored. Ignoring one
// runs a weaker query that returns more than was asked for and reports no
// error, which is the failure that is hardest to notice.
//
// Order matters: the SDK requires an ordering before a bound, and applying a
// bound first silently produces a different query.
bool ApplyQuerySpec(firebase::database::Query* q,
                    const std::map<std::string, Variant>& spec) {
  static const char* kKnown[] = {
      "orderBy", "orderByPath", "startAt", "startAtKey", "endAt",
      "endAtKey", "equalTo", "equalToKey", "limitToFirst", "limitToLast"};
  for (const auto& kv : spec) {
    bool known = false;
    for (const char* k : kKnown) {
      if (kv.first == k) { known = true; break; }
    }
    if (!known) return false;
  }

  auto find = [&spec](const char* key) -> const Variant* {
    auto it = spec.find(key);
    return it == spec.end() ? nullptr : &it->second;
  };

  if (const Variant* order = find("orderBy")) {
    if (!order->is_string()) return false;
    const std::string by = order->string_value();
    if (by == "child") {
      const Variant* path = find("orderByPath");
      if (path == nullptr || !path->is_string()) return false;
      *q = q->OrderByChild(path->string_value());
    } else if (by == "key") {
      *q = q->OrderByKey();
    } else if (by == "value") {
      *q = q->OrderByValue();
    } else if (by == "priority") {
      *q = q->OrderByPriority();
    } else {
      return false;
    }
  } else if (find("orderByPath") != nullptr) {
    // A path with nothing to order by is a spec that means nothing.
    return false;
  }

  // equalTo is StartAt and EndAt at once; combining it with either is a
  // contradiction rather than a narrowing.
  const Variant* equal = find("equalTo");
  if (equal != nullptr && (find("startAt") || find("endAt"))) return false;

  if (equal != nullptr) {
    const Variant* key = find("equalToKey");
    if (key != nullptr) {
      if (!key->is_string()) return false;
      *q = q->EqualTo(*equal, key->string_value());
    } else {
      *q = q->EqualTo(*equal);
    }
  }
  if (const Variant* start = find("startAt")) {
    const Variant* key = find("startAtKey");
    if (key != nullptr) {
      if (!key->is_string()) return false;
      *q = q->StartAt(*start, key->string_value());
    } else {
      *q = q->StartAt(*start);
    }
  }
  if (const Variant* end = find("endAt")) {
    const Variant* key = find("endAtKey");
    if (key != nullptr) {
      if (!key->is_string()) return false;
      *q = q->EndAt(*end, key->string_value());
    } else {
      *q = q->EndAt(*end);
    }
  }

  const Variant* first = find("limitToFirst");
  const Variant* last = find("limitToLast");
  // The SDK keeps whichever was applied last rather than reporting the
  // conflict, so asking for both is refused here.
  if (first != nullptr && last != nullptr) return false;
  if (first != nullptr) {
    if (!first->is_int64() || first->int64_value() <= 0) return false;
    *q = q->LimitToFirst(static_cast<size_t>(first->int64_value()));
  }
  if (last != nullptr) {
    if (!last->is_int64() || last->int64_value() <= 0) return false;
    *q = q->LimitToLast(static_cast<size_t>(last->int64_value()));
  }
  return true;
}

}  // namespace
}  // extern "C++"

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

// A priority orders a node's siblings. It is written with the value, because
// the SDK writes both in one operation -- setting a value and then a priority
// is two writes, and a listener sees the node between them with the old order.
FDB_EXPORT int64_t fdb_db_set_with_priority(const char* path,
                                            const uint8_t* cbor, size_t len,
                                            const uint8_t* prio, size_t prio_len,
                                            int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  Variant priority;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  if (!fdb::ParseVariant(prio, prio_len, &priority)) return -3;
  g_database->GetReference(path)
      .SetValueAndPriority(value, priority)
      .OnCompletion([port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_db_set_priority(const char* path, const uint8_t* prio,
                                       size_t prio_len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant priority;
  if (!fdb::ParseVariant(prio, prio_len, &priority)) return -3;
  g_database->GetReference(path).SetPriority(priority).OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Keeps a location synced even with no listener attached, so a later read is
// served from cache rather than the network. Nothing completes: the SDK takes
// the instruction and applies it to the sync tree.
FDB_EXPORT int64_t fdb_db_keep_synced(const char* path, const uint8_t* spec,
                                      size_t spec_len, int32_t keep) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  firebase::database::Query query = g_database->GetReference(path);
  if (spec != nullptr && spec_len > 0) {
    std::map<std::string, Variant> parsed;
    if (!fdb::ParseVariantMap(spec, spec_len, &parsed)) return -3;
    if (!ApplyQuerySpec(&query, parsed)) return -3;
  }
  query.SetKeepSynchronized(keep != 0);
  return 0;
}

// Drops writes that have not reached the server. Their futures fail, which is
// the point: an app that gave up on a write needs to hear that it will not
// land rather than wait forever.
FDB_EXPORT int64_t fdb_db_purge_outstanding_writes(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  g_database->PurgeOutstandingWrites();
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

// What the server should do if this client goes away without saying goodbye.
//
// Registered with the server now and executed by it on disconnect, which is
// the only kind of cleanup that survives a device losing power rather than
// closing down: nothing on the device gets to run at that point.
//
// The registration is what completes here. Whether the server later carries it
// out is not something a client can observe, and reporting the registration as
// though it were the write would claim more than is known.
FDB_EXPORT int64_t fdb_db_on_disconnect_set(const char* path,
                                            const uint8_t* cbor, size_t len,
                                            int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  g_database->GetReference(path).OnDisconnect()->SetValue(value).OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_db_on_disconnect_update(const char* path,
                                               const uint8_t* cbor, size_t len,
                                               int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  if (!value.is_map()) return -4;
  g_database->GetReference(path)
      .OnDisconnect()
      ->UpdateChildren(value)
      .OnCompletion([port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_db_on_disconnect_set_with_priority(
    const char* path, const uint8_t* cbor, size_t len, const uint8_t* prio,
    size_t prio_len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  Variant value;
  Variant priority;
  if (!fdb::ParseVariant(cbor, len, &value)) return -3;
  if (!fdb::ParseVariant(prio, prio_len, &priority)) return -3;
  g_database->GetReference(path)
      .OnDisconnect()
      ->SetValueAndPriority(value, priority)
      .OnCompletion([port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

FDB_EXPORT int64_t fdb_db_on_disconnect_remove(const char* path,
                                               int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  g_database->GetReference(path).OnDisconnect()->RemoveValue().OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Drops every registration made for this path, not just the last one.
FDB_EXPORT int64_t fdb_db_on_disconnect_cancel(const char* path,
                                               int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;
  g_database->GetReference(path).OnDisconnect()->Cancel().OnCompletion(
      [port](const firebase::Future<void>& f) {
        fdb_post_outcome(port, f.error() == 0 ? 1 : 0, f.error(),
                         f.error_message() == nullptr ? "" : f.error_message());
      });
  return 0;
}

// Transactions.
//
// The SDK calls the handler on its own thread and wants a decision before that
// call returns; the handler lives in Dart. So the SDK's thread is parked on a
// condition variable while the current value goes to Dart, and
// fdb_db_txn_apply wakes it with the answer. The same shape the Firestore
// transactions use, for the same reason.
//
// The handler is called again for each retry -- the SDK re-runs it when the
// value changed underneath -- so an attempt number goes with each request, and
// a Dart handler must be prepared to run more than once.
// extern "C++" for the same reason as the query helpers above: an anonymous
// namespace inside extern "C" does not make these internal. firestore_impl.cpp
// has its own g_next_txn, and the two collided at link time -- but only in a
// build that compiles both, which a product selection without Firestore does
// not.
extern "C++" {
namespace {

struct DbTxnState {
  std::mutex m;
  std::condition_variable cv;
  bool answered = false;
  bool abort = false;
  bool value_is_null = false;
  std::vector<uint8_t> value;
  Dart_Port_DL port = 0;
  int64_t attempt = 0;
};

std::map<int64_t, std::shared_ptr<DbTxnState>> g_db_txns;
int64_t g_next_db_txn = 1;

}  // namespace
}  // extern "C++"

// Drops the connection and restores it. Bound because it is the only way to
// see a disconnect handler actually run: registering one is easy to verify,
// and whether the server carries it out is the part that matters.
FDB_EXPORT int64_t fdb_db_go_offline(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  g_database->GoOffline();
  return 0;
}

FDB_EXPORT int64_t fdb_db_go_online(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  g_database->GoOnline();
  return 0;
}

// Runs a transaction at `path`. Returns a transaction id, or negative.
//
// Each attempt posts the current value to `port` with an increasing seq; the
// handler answers with fdb_db_txn_apply. The final outcome arrives on the same
// port with seq 0 on success, or a negative seq carrying the reason.
FDB_EXPORT int64_t fdb_db_txn_run(const char* path, int64_t port) {
  std::shared_ptr<DbTxnState> state;
  int64_t id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (EnsureDatabase() == nullptr) return -1;
    if (path == nullptr) return -2;
    state = std::make_shared<DbTxnState>();
    state->port = static_cast<Dart_Port_DL>(port);
    id = g_next_db_txn++;
    g_db_txns.emplace(id, state);
  }

  firebase::database::DatabaseReference ref = g_database->GetReference(path);
  ref.RunTransaction([state](firebase::database::MutableData* data)
                         -> firebase::database::TransactionResult {
        std::vector<uint8_t> payload;
        if (!fdb::SerializeVariant(data->value(), payload)) {
          return firebase::database::kTransactionResultAbort;
        }

        std::unique_lock<std::mutex> lock(state->m);
        state->answered = false;
        const int64_t attempt = ++state->attempt;
        lock.unlock();

        // Posted outside the lock: fdb_db_txn_apply takes it, and Dart can
        // answer before this thread reaches the wait.
        fdb_post_buffer(state->port, attempt, payload.data(), payload.size());

        lock.lock();
        state->cv.wait(lock, [&state] { return state->answered; });
        if (state->abort) {
          return firebase::database::kTransactionResultAbort;
        }
        Variant next;
        if (state->value_is_null) {
          next = Variant::Null();
        } else if (!fdb::ParseVariant(state->value.data(), state->value.size(),
                                      &next)) {
          return firebase::database::kTransactionResultAbort;
        }
        data->set_value(next);
        return firebase::database::kTransactionResultSuccess;
      })
      .OnCompletion([state, id](
                        const firebase::Future<
                            firebase::database::DataSnapshot>& f) {
        if (f.error() != 0) {
          const char* msg =
              f.error_message() == nullptr ? "" : f.error_message();
          fdb_post_buffer(state->port, -(f.error() == 0 ? 1 : f.error()),
                          reinterpret_cast<const uint8_t*>(msg), strlen(msg));
        } else {
          // seq 0 is the terminal event, matching the Firestore transactions.
          std::vector<uint8_t> payload;
          if (f.result() != nullptr &&
              fdb::SerializeVariant(f.result()->value(), payload)) {
            fdb_post_buffer(state->port, 0, payload.data(), payload.size());
          } else {
            fdb_post_buffer(state->port, 0, nullptr, 0);
          }
        }
        std::lock_guard<std::mutex> lock(g_mutex);
        g_db_txns.erase(id);
      });
  return id;
}

// Answers the attempt the SDK is parked on. `abort` non-zero abandons the
// transaction; otherwise the CBOR is the new value, and a null payload with
// len 0 means write null.
FDB_EXPORT int64_t fdb_db_txn_apply(int64_t txn_id, const uint8_t* cbor,
                                    size_t len, int32_t abort) {
  std::shared_ptr<DbTxnState> state;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto it = g_db_txns.find(txn_id);
    if (it == g_db_txns.end()) return -1;
    state = it->second;
  }
  {
    std::lock_guard<std::mutex> lock(state->m);
    state->abort = abort != 0;
    state->value_is_null = (cbor == nullptr || len == 0);
    state->value.assign(cbor, cbor + (state->value_is_null ? 0 : len));
    state->answered = true;
  }
  state->cv.notify_one();
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
  const int64_t handle = g_next_value_handle++;
  auto listener = std::make_unique<PortValueListener>(
      static_cast<Dart_Port_DL>(port), g_database->GetReference(path));
  listener->query().AddValueListener(listener.get());
  g_listeners.emplace(handle, std::move(listener));
  return handle;
}

// The same query, watched, with a spec applied. Returns a handle for
// fdb_db_unlisten, or -3 for a spec this ABI cannot apply -- refused rather
// than run as a weaker query, which would deliver more than was asked for and
// report nothing wrong.
FDB_EXPORT int64_t fdb_db_query_listen(const char* path, const uint8_t* spec,
                                       size_t spec_len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;

  firebase::database::Query query = g_database->GetReference(path);
  if (spec != nullptr && spec_len > 0) {
    std::map<std::string, Variant> parsed;
    if (!fdb::ParseVariantMap(spec, spec_len, &parsed)) return -3;
    if (!ApplyQuerySpec(&query, parsed)) return -3;
  }

  const int64_t handle = g_next_value_handle++;
  auto listener = std::make_unique<PortValueListener>(
      static_cast<Dart_Port_DL>(port), std::move(query));
  listener->query().AddValueListener(listener.get());
  g_listeners.emplace(handle, std::move(listener));
  return handle;
}

// Child events rather than whole-node snapshots. Same spec, same codes.
FDB_EXPORT int64_t fdb_db_child_listen(const char* path, const uint8_t* spec,
                                       size_t spec_len, int64_t port) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (EnsureDatabase() == nullptr) return -1;
  if (path == nullptr) return -2;

  firebase::database::Query query = g_database->GetReference(path);
  if (spec != nullptr && spec_len > 0) {
    std::map<std::string, Variant> parsed;
    if (!fdb::ParseVariantMap(spec, spec_len, &parsed)) return -3;
    if (!ApplyQuerySpec(&query, parsed)) return -3;
  }

  // Negative so one unlisten serves both kinds without the caller having to
  // say which it started; below -1000 so it cannot be read as an error code.
  const int64_t handle = -(g_next_child_handle++);
  auto listener = std::make_unique<PortChildListener>(
      static_cast<Dart_Port_DL>(port), std::move(query));
  listener->query().AddChildListener(listener.get());
  g_child_listeners.emplace(handle, std::move(listener));
  return handle;
}

FDB_EXPORT void fdb_db_unlisten(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (handle < 0) {
    const auto it = g_child_listeners.find(handle);
    if (it == g_child_listeners.end()) return;
    it->second->query().RemoveChildListener(it->second.get());
    g_child_listeners.erase(it);
    return;
  }
  const auto it = g_listeners.find(handle);
  if (it == g_listeners.end()) {
    return;
  }
  // Remove before destroying: the SDK holds a raw pointer to the listener.
  it->second->query().RemoveValueListener(it->second.get());
  g_listeners.erase(it);
}

}  // extern "C"
