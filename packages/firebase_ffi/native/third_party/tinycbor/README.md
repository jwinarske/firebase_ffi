# TinyCBOR (vendored)

Upstream: https://github.com/intel/tinycbor, tag **v7.0**, MIT.
`LICENSE` is upstream's, unmodified.

Only the encoder, the parser and its dup-string helper are here — not the JSON conversion, pretty-printer,
validation or `open_memstream` shim, none of which this module uses.

Vendored rather than fetched so the build stays offline and reproducible, the
same reason `native/src/dart_api_dl.c` and the `dart_api*.h` headers are
checked in. Sources are unmodified; update by re-fetching a tag rather than by
editing in place.
