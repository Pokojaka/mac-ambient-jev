#ifndef MSJ_CSHA256_H
#define MSJ_CSHA256_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Compress block_count consecutive 64-byte blocks into an existing SHA-256 state.
 * block_count must be positive. blocks must be non-null and point to at least
 * block_count * 64 readable bytes. state points to exactly 8 words.
 */
void msj_sha256_compress_blocks(uint32_t state[8], const uint8_t *blocks, size_t block_count);

#ifdef __cplusplus
}
#endif

#endif /* MSJ_CSHA256_H */
