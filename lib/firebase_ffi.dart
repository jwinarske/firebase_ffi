/// Transport benchmark for a Realtime Database plugin built on FFI rather than
/// a platform channel.
///
/// Measures three things, and is careful about what each one means:
///
///  * **Channel A dispatch** — what a `ref().set()` costs on this side of the
///    boundary. Network time is not this layer's and is not measured.
///  * **Channel B1 delivery** — post to Dart-readable for one snapshot, using
///    `kExternalTypedData`, where the `Uint8List` *is* the C allocation.
///  * **A copying post** — the same payload as `kTypedData`, which the VM
///    copies into the Dart heap. This is the floor any codec-based channel
///    pays, before its own encode and decode, so the gap between it and B1 is
///    the copy alone, not the whole platform-channel saving.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/ffi/bindings.dart';

/// One measured distribution, reported by percentile: a mean hides the tail
/// that matters on a Pi, where a page fault or a migration shows up as p99.
class Stats {
  Stats(List<int> samplesNs) : _s = List<int>.of(samplesNs)..sort();
  final List<int> _s;

  int get count => _s.length;
  int get min => _s.first;
  int get p50 => _s[_s.length ~/ 2];
  int get p99 => _s[(_s.length * 99) ~/ 100];
  int get max => _s.last;
  double get meanNs => _s.reduce((a, b) => a + b) / _s.length;

  @override
  String toString() =>
      'n=$count  min=${min}ns  p50=${p50}ns  p99=${p99}ns  max=${max}ns';
}

/// Initializes the bridge. Must run before anything posts to a port.
void initBridge() {
  final rc = fdbInitDartApi(NativeApi.initializeApiDLData);
  if (rc != 0) {
    throw StateError('Dart_InitializeApiDL failed: $rc');
  }
}

/// Channel A: the cost of an FFI call that does nothing, which is the floor
/// everything else sits on.
Stats benchNoop({int iterations = 20000, int warmup = 2000}) {
  for (var i = 0; i < warmup; i++) {
    fdbNoop();
  }
  final samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    final t0 = fdbNowNs();
    fdbNoop();
    samples.add(fdbNowNs() - t0);
  }
  return Stats(samples);
}

/// Channel A: a write of [valueBytes], measured as dispatch.
///
/// The buffer and path are allocated once outside the loop on purpose. A real
/// caller marshals its own payload; folding that allocation into the sample
/// would measure Dart's allocator rather than the boundary crossing.
Stats benchSet({
  int valueBytes = 256,
  int iterations = 20000,
  int warmup = 2000,
}) {
  final path = '/bench/node'.toNativeUtf8();
  final buf = calloc<Uint8>(valueBytes);
  try {
    for (var i = 0; i < warmup; i++) {
      fdbSet(path.cast(), buf, valueBytes);
    }
    final samples = <int>[];
    for (var i = 0; i < iterations; i++) {
      final t0 = fdbNowNs();
      fdbSet(path.cast(), buf, valueBytes);
      samples.add(fdbNowNs() - t0);
    }
    return Stats(samples);
  } finally {
    calloc.free(buf);
    calloc.free(path);
  }
}

/// Channel B1: post-to-readable for [valueBytes], one snapshot at a time.
///
/// Each emission is awaited before the next, so the number is delivery latency
/// rather than throughput under a backlog. The native side stamps `posted_ns`
/// from the same clock `fdbNowNs` reads, which is what makes a cross-thread
/// one-way measurement meaningful at all.
///
/// [copying] switches to `kTypedData`, where the VM copies the payload.
Future<Stats> benchSnapshot({
  int valueBytes = 4096,
  int iterations = 2000,
  int warmup = 200,
  bool copying = false,
}) async {
  final port = ReceivePort();
  final path = '/bench/watch'.toNativeUtf8();
  final handle = fdbListen(path.cast(), port.sendPort.nativePort);

  final samples = <int>[];
  var seq = 0;
  Completer<void>? pending;

  final sub = port.listen((message) {
    final bytes = message as Uint8List;
    final received = fdbNowNs();

    // Read the header in place out of the external typed data. For B1 this
    // touches the C allocation directly; nothing is decoded.
    final view = ByteData.sublistView(bytes);
    final magic = view.getUint32(0, Endian.host);
    if (magic != fdbSnapshotMagic) {
      throw StateError('bad snapshot magic: 0x${magic.toRadixString(16)}');
    }
    // Offsets into FdbSnapshotHeader: magic 0, version 4, seq 8, posted_ns 16.
    final postedNs = view.getInt64(16, Endian.host);
    final elapsed = received - postedNs;
    if (elapsed < 0 || elapsed > 10000000000) {
      throw StateError('implausible latency ${elapsed}ns — header offset drift');
    }
    samples.add(elapsed);

    pending?.complete();
  });

  try {
    for (var i = 0; i < warmup + iterations; i++) {
      final done = Completer<void>();
      pending = done;
      seq++;
      if (copying) {
        fdbEmitSnapshotCopying(handle, seq, valueBytes);
      } else {
        fdbEmitSnapshot(handle, seq, valueBytes);
      }
      await done.future;
      if (i == warmup - 1) samples.clear();
    }
    return Stats(samples);
  } finally {
    await sub.cancel();
    port.close();
    fdbUnlisten(handle);
    calloc.free(path);
  }
}

/// Runs the whole set and returns it as lines, so a caller can print them
/// wherever its output goes — stdout on a host, the embedder's log on a board.
Future<List<String>> runBenchmarks() async {
  initBridge();
  final out = <String>[];

  out.add('channel A  noop            ${benchNoop()}');
  for (final size in [64, 256, 4096]) {
    out.add('channel A  set ${size.toString().padLeft(5)}B       '
        '${benchSet(valueBytes: size)}');
  }
  for (final size in [1024, 16384, 262144]) {
    final ext = await benchSnapshot(valueBytes: size);
    final cop = await benchSnapshot(valueBytes: size, copying: true);
    out.add('channel B1 ${size.toString().padLeft(7)}B external  $ext');
    out.add('           ${size.toString().padLeft(7)}B copying   $cop');
    final delta = cop.p50 - ext.p50;
    final pct = ext.p50 == 0 ? 0.0 : (delta / cop.p50) * 100;
    out.add('           ${size.toString().padLeft(7)}B saving    '
        '${delta}ns at p50 (${pct.toStringAsFixed(1)}%)');
  }
  return out;
}
