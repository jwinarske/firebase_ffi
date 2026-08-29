/* Included when CBOR_EXTERNAL_CFG is defined. TinyCBOR's own CMake normally
 * generates the equivalent; this project compiles the sources directly into a
 * static object, so the API macros carry no linkage decoration. */
#ifndef CBOR_CFG_H
#define CBOR_CFG_H
#define CBOR_API
#endif
