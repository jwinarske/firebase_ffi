// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// The native half of the codec, which had no tests until a sizing bug shipped
// in both encoders and only showed up against a live backend.
//
// Containers are the point. The bug was invisible for scalars: a measuring
// pass against a null buffer only fails once something calls
// cbor_encoder_create_map or _create_array, so a string round-tripped happily
// while every map was truncated. Several cases here exist purely to force the
// grow-and-retry loop round more than once.
//
// No test framework: a failure prints and returns non-zero, which is all ctest
// needs, and it keeps a third dependency out of a library that links four.

#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "cbor.h"
#include "fdb_cbor.h"
#include "firebase_bridge.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool ok, const char* what) {
  ++g_checks;
  if (!ok) {
    std::printf("  FAIL %s\n", what);
    ++g_failures;
  }
}

// Decodes with an independent walk, so a bug that is symmetric in our encoder
// and decoder cannot hide.
bool WellFormed(const std::vector<uint8_t>& bytes, CborType* top) {
  CborParser parser;
  CborValue it;
  if (cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it) !=
      CborNoError) {
    return false;
  }
  *top = cbor_value_get_type(&it);
  // Walk the whole value rather than calling cbor_value_validate: that lives in
  // cborvalidation.c, which is not vendored, and advancing over every element
  // is the property being checked anyway — a truncated container fails here.
  return cbor_value_advance(&it) == CborNoError && cbor_value_at_end(&it);
}

using firebase::Variant;

void TestVariantScalars() {
  const Variant values[] = {
      Variant::Null(),        Variant(true),
      Variant(int64_t{-42}),  Variant(1.5),
      Variant("hello"),
  };
  for (const auto& v : values) {
    std::vector<uint8_t> out;
    Check(fdb::SerializeVariant(v, out), "scalar encodes");
    CborType top;
    Check(WellFormed(out, &top), "scalar is well-formed CBOR");
  }
}

void TestVariantContainers() {
  // The case the shipped bug broke: a map needs create_map, which fails during
  // a null-buffer measuring pass.
  std::map<Variant, Variant> m;
  m[Variant("a")] = Variant(int64_t{1});
  m[Variant("b")] = Variant("two");
  std::vector<uint8_t> out;
  Check(fdb::SerializeVariant(Variant(m), out), "map encodes");
  CborType top;
  Check(WellFormed(out, &top), "map is well-formed");
  Check(top == CborMapType, "map decodes as a map");

  std::vector<Variant> v{Variant(int64_t{1}), Variant("x"), Variant::Null()};
  out.clear();
  Check(fdb::SerializeVariant(Variant(v), out), "vector encodes");
  Check(WellFormed(out, &top), "vector is well-formed");
  Check(top == CborArrayType, "vector decodes as an array");
}

void TestVariantNested() {
  std::vector<Variant> inner{Variant(int64_t{1}), Variant(int64_t{2})};
  std::map<Variant, Variant> m;
  m[Variant("list")] = Variant(inner);
  std::map<Variant, Variant> outer;
  outer[Variant("nested")] = Variant(m);
  std::vector<uint8_t> out;
  Check(fdb::SerializeVariant(Variant(outer), out), "nested encodes");
  CborType top;
  Check(WellFormed(out, &top), "nested is well-formed");
}

void TestVariantGrows() {
  // Larger than the initial 512-byte buffer, so the retry loop must run. A
  // sizing bug that under-counts fails here even when small maps pass.
  std::map<Variant, Variant> m;
  for (int i = 0; i < 200; ++i) {
    m[Variant("key_" + std::to_string(i))] =
        Variant(std::string(64, 'x') + std::to_string(i));
  }
  std::vector<uint8_t> out;
  Check(fdb::SerializeVariant(Variant(m), out), "large map encodes");
  Check(out.size() > 512, "large map exceeds the initial buffer");
  CborType top;
  Check(WellFormed(out, &top), "large map is well-formed");

  // And the buffer is trimmed to what was written, not left at the grown size.
  CborParser parser;
  CborValue it;
  cbor_parser_init(out.data(), out.size(), 0, &parser, &it);
  CborValue tail = it;
  cbor_value_advance(&tail);
  Check(cbor_value_get_next_byte(&tail) == out.data() + out.size(),
        "no slack left after the encoded value");
}

void TestBlob() {
  const uint8_t raw[] = {1, 2, 250};
  std::vector<uint8_t> out;
  Check(fdb::SerializeVariant(Variant::FromStaticBlob(raw, sizeof(raw)), out),
        "blob encodes");
  CborType top;
  Check(WellFormed(out, &top), "blob is well-formed");
  Check(top == CborByteStringType, "blob is a CBOR byte string");
}

#if defined(FDB_HAVE_FIRESTORE)

using firebase::firestore::FieldValue;
using firebase::firestore::MapFieldValue;

// A document survives encode -> decode with its types intact. Both halves are
// ours, so this pins the pair rather than either alone; the Dart tests pin the
// wire format against an independent implementation.
void TestFirestoreRoundTrip() {
  MapFieldValue doc;
  doc["text"] = FieldValue::String("hello");
  doc["count"] = FieldValue::Integer(42);
  doc["ratio"] = FieldValue::Double(1.5);
  doc["flag"] = FieldValue::Boolean(true);
  doc["nothing"] = FieldValue::Null();
  const uint8_t raw[] = {1, 2, 250};
  doc["bytes"] = FieldValue::Blob(raw, sizeof(raw));
  doc["when"] = FieldValue::Timestamp(firebase::Timestamp(1735689600, 123456789));
  doc["where"] = FieldValue::GeoPoint(firebase::firestore::GeoPoint(51.5, -0.12));
  doc["list"] = FieldValue::Array({FieldValue::Integer(1),
                                   FieldValue::String("two")});
  MapFieldValue nested;
  nested["deep"] = FieldValue::Boolean(true);
  doc["nested"] = FieldValue::Map(nested);

  std::vector<uint8_t> bytes;
  Check(fdb::SerializeDocument(doc, bytes), "document encodes");
  CborType top;
  Check(WellFormed(bytes, &top), "document is well-formed");
  Check(top == CborMapType, "document is a CBOR map");

  MapFieldValue back;
  Check(fdb::ParseDocumentCbor(bytes.data(), bytes.size(), &back),
        "document decodes");
  Check(back.size() == doc.size(), "field count survives");

  Check(back["text"] == FieldValue::String("hello"), "string survives");
  Check(back["count"] == FieldValue::Integer(42), "integer survives");
  Check(back["flag"] == FieldValue::Boolean(true), "bool survives");
  Check(back["nothing"].is_null(), "null survives");
  // The reason timestamps are a pair of integers rather than RFC 8949 tag 1:
  // a float64 epoch cannot carry this.
  Check(back["when"].timestamp_value().nanoseconds() == 123456789,
        "timestamp keeps its nanoseconds");
  Check(back["where"].geo_point_value().latitude() == 51.5,
        "geopoint survives");
  Check(back["bytes"].blob_size() == 3, "blob length survives");
  Check(back["list"].array_value().size() == 2, "array survives");
  Check(back["nested"].map_value().size() == 1, "nested map survives");
}

// Sentinels travel Dart -> native only. The decoder must accept them, because
// a write legitimately carries one.
void TestFirestoreSentinels() {
  // { "gone": 40010(null) } — the delete sentinel, hand-built so the test does
  // not depend on our own encoder to produce it.
  std::vector<uint8_t> buf(64);
  CborEncoder enc, map;
  cbor_encoder_init(&enc, buf.data(), buf.size(), 0);
  cbor_encoder_create_map(&enc, &map, 1);
  cbor_encode_text_string(&map, "gone", 4);
  cbor_encode_tag(&map, FDB_CBOR_TAG_DELETE);
  cbor_encode_null(&map);
  cbor_encoder_close_container(&enc, &map);
  buf.resize(cbor_encoder_get_buffer_size(&enc, buf.data()));

  MapFieldValue out;
  Check(fdb::ParseDocumentCbor(buf.data(), buf.size(), &out),
        "delete sentinel decodes");
  Check(out.size() == 1, "sentinel lands as a field");
}

// A tag this build does not know must be refused, not written through without
// the meaning the tag carried.
void TestFirestoreUnknownTag() {
  std::vector<uint8_t> buf(64);
  CborEncoder enc, map;
  cbor_encoder_init(&enc, buf.data(), buf.size(), 0);
  cbor_encoder_create_map(&enc, &map, 1);
  cbor_encode_text_string(&map, "x", 1);
  cbor_encode_tag(&map, 49999);
  cbor_encode_int(&map, 1);
  cbor_encoder_close_container(&enc, &map);
  buf.resize(cbor_encoder_get_buffer_size(&enc, buf.data()));

  MapFieldValue out;
  Check(!fdb::ParseDocumentCbor(buf.data(), buf.size(), &out),
        "an unknown tag is refused");
}

void TestFirestoreGrows() {
  MapFieldValue doc;
  for (int i = 0; i < 200; ++i) {
    doc["key_" + std::to_string(i)] =
        FieldValue::String(std::string(64, 'y') + std::to_string(i));
  }
  std::vector<uint8_t> bytes;
  Check(fdb::SerializeDocument(doc, bytes), "large document encodes");
  Check(bytes.size() > 512, "large document exceeds the initial buffer");
  MapFieldValue back;
  Check(fdb::ParseDocumentCbor(bytes.data(), bytes.size(), &back),
        "large document decodes");
  Check(back.size() == 200, "every field survives");
}

#endif  // FDB_HAVE_FIRESTORE

#if defined(FDB_HAVE_STORAGE)

// Counts the top-level entries of an encoded map, walking independently of the
// encoder that produced it.
int MapEntries(const std::vector<uint8_t>& bytes) {
  CborParser parser;
  CborValue it;
  if (cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it) !=
      CborNoError) {
    return -1;
  }
  if (!cbor_value_is_map(&it)) return -1;
  CborValue entry;
  if (cbor_value_enter_container(&it, &entry) != CborNoError) return -1;
  int n = 0;
  while (!cbor_value_at_end(&entry)) {
    // Key and value; advance over both.
    if (cbor_value_advance(&entry) != CborNoError) return -1;
    if (cbor_value_at_end(&entry)) return -1;
    if (cbor_value_advance(&entry) != CborNoError) return -1;
    ++n;
  }
  return n;
}

bool Contains(const std::vector<uint8_t>& bytes, const char* needle) {
  const std::string hay(reinterpret_cast<const char*>(bytes.data()),
                        bytes.size());
  return hay.find(needle) != std::string::npos;
}

void TestStorageMetadata() {
  firebase::storage::Metadata m;
  m.set_content_type("image/png");
  m.set_cache_control("max-age=3600");

  std::vector<uint8_t> out;
  Check(fdb::SerializeMetadata(m, out), "metadata encodes");
  CborType top = CborInvalidType;
  Check(WellFormed(out, &top) && top == CborMapType, "metadata is a CBOR map");
  Check(Contains(out, "contentType"), "content type is carried");
  Check(Contains(out, "image/png"), "content type value is carried");
  Check(Contains(out, "cacheControl"), "cache control is carried");
  // Absent fields are omitted rather than written empty: the Dart side reads
  // absence as null, and an empty string would claim the field was set.
  Check(!Contains(out, "contentEncoding"), "an unset field is omitted");
}

void TestStorageMetadataGrows() {
  firebase::storage::Metadata m;
  m.set_content_type("application/octet-stream");
  // Past any plausible starting buffer, so the encoder has to grow and retry.
  // Sizing by measuring against a null buffer got this wrong once already:
  // the walk stopped at the first container and the real pass overflowed.
  std::map<std::string, std::string>* custom = m.custom_metadata();
  Check(custom != nullptr, "custom metadata is writable");
  if (custom != nullptr) {
    for (int i = 0; i < 200; ++i) {
      (*custom)["key-with-a-long-enough-name-" + std::to_string(i)] =
          "value-with-a-long-enough-body-" + std::to_string(i);
    }
  }

  std::vector<uint8_t> out;
  Check(fdb::SerializeMetadata(m, out), "a large metadata map encodes");
  CborType top = CborInvalidType;
  Check(WellFormed(out, &top) && top == CborMapType,
        "a large metadata map is well formed");
  Check(out.size() > 512, "it outgrew the starting buffer");
  Check(Contains(out, "key-with-a-long-enough-name-199"),
        "the last custom entry survived");
  // The named fields plus the one `custom` key.
  Check(MapEntries(out) >= 3, "the top-level map kept its own fields");
}

#endif  // FDB_HAVE_STORAGE

}  // namespace

// The estimate is what sizes the buffer, so a value it under-counts would
// cost a second encode — or, if the retry were ever dropped, a truncated
// snapshot. Checked against the encoder itself.
void TestEstimateIsUpperBound() {
  std::vector<Variant> values;
  values.push_back(Variant::Null());
  values.push_back(Variant(true));
  values.push_back(Variant(int64_t{-9223372036854775807LL}));
  values.push_back(Variant(3.14159));
  values.push_back(Variant("a string with some length to it"));
  const std::vector<uint8_t> big(256 * 1024, 7);
  values.push_back(Variant::FromMutableBlob(big.data(), big.size()));

  std::map<Variant, Variant> nested;
  nested["name"] = Variant("kiosk-7");
  nested["tags"] = Variant(std::vector<Variant>{Variant("lobby"),
                                                Variant("north")});
  nested["site"] = Variant(std::map<Variant, Variant>{
      {Variant("building"), Variant("A")}, {Variant("floor"), Variant(2)}});
  values.push_back(Variant(nested));

  for (const Variant& v : values) {
    std::vector<uint8_t> out;
    Check(fdb::SerializeVariant(v, out), "estimate: serialized");
    Check(fdb::EstimateVariantBytes(v) >= out.size(),
          "estimate: bound holds");
  }
}

int main() {
  std::printf("codec_test\n");
  TestEstimateIsUpperBound();
  TestVariantScalars();
  TestVariantContainers();
  TestVariantNested();
  TestVariantGrows();
  TestBlob();
#if defined(FDB_HAVE_STORAGE)
  TestStorageMetadata();
  TestStorageMetadataGrows();
#endif
#if defined(FDB_HAVE_FIRESTORE)
  TestFirestoreRoundTrip();
  TestFirestoreSentinels();
  TestFirestoreUnknownTag();
  TestFirestoreGrows();
#endif
  if (g_failures == 0) {
    // Printed so a section silently compiled out by an #if is visible as a
    // drop in the count rather than as a pass.
    std::printf("  %d checks passed\n", g_checks);
    return 0;
  }
  std::printf("  %d check(s) failed\n", g_failures);
  return 1;
}
