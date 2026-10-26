#include "CSHA256.h"

/* SHA-256 compression per FIPS 180-4 (Aug. 2015), §§ 4.1.2, 4.2.2, 6.2.2:
 * https://csrc.nist.gov/pubs/fips/180-4/upd1/final
 */
static const uint32_t round_constants[64] = {
    UINT32_C(0x428a2f98), UINT32_C(0x71374491), UINT32_C(0xb5c0fbcf), UINT32_C(0xe9b5dba5),
    UINT32_C(0x3956c25b), UINT32_C(0x59f111f1), UINT32_C(0x923f82a4), UINT32_C(0xab1c5ed5),
    UINT32_C(0xd807aa98), UINT32_C(0x12835b01), UINT32_C(0x243185be), UINT32_C(0x550c7dc3),
    UINT32_C(0x72be5d74), UINT32_C(0x80deb1fe), UINT32_C(0x9bdc06a7), UINT32_C(0xc19bf174),
    UINT32_C(0xe49b69c1), UINT32_C(0xefbe4786), UINT32_C(0x0fc19dc6), UINT32_C(0x240ca1cc),
    UINT32_C(0x2de92c6f), UINT32_C(0x4a7484aa), UINT32_C(0x5cb0a9dc), UINT32_C(0x76f988da),
    UINT32_C(0x983e5152), UINT32_C(0xa831c66d), UINT32_C(0xb00327c8), UINT32_C(0xbf597fc7),
    UINT32_C(0xc6e00bf3), UINT32_C(0xd5a79147), UINT32_C(0x06ca6351), UINT32_C(0x14292967),
    UINT32_C(0x27b70a85), UINT32_C(0x2e1b2138), UINT32_C(0x4d2c6dfc), UINT32_C(0x53380d13),
    UINT32_C(0x650a7354), UINT32_C(0x766a0abb), UINT32_C(0x81c2c92e), UINT32_C(0x92722c85),
    UINT32_C(0xa2bfe8a1), UINT32_C(0xa81a664b), UINT32_C(0xc24b8b70), UINT32_C(0xc76c51a3),
    UINT32_C(0xd192e819), UINT32_C(0xd6990624), UINT32_C(0xf40e3585), UINT32_C(0x106aa070),
    UINT32_C(0x19a4c116), UINT32_C(0x1e376c08), UINT32_C(0x2748774c), UINT32_C(0x34b0bcb5),
    UINT32_C(0x391c0cb3), UINT32_C(0x4ed8aa4a), UINT32_C(0x5b9cca4f), UINT32_C(0x682e6ff3),
    UINT32_C(0x748f82ee), UINT32_C(0x78a5636f), UINT32_C(0x84c87814), UINT32_C(0x8cc70208),
    UINT32_C(0x90befffa), UINT32_C(0xa4506ceb), UINT32_C(0xbef9a3f7), UINT32_C(0xc67178f2)
};

/* All call sites use rotation counts from 1 through 31. */
static uint32_t rotate_right(uint32_t value, unsigned int amount) {
    return (value >> amount) | (value << (32U - amount));
}

void msj_sha256_compress_blocks(uint32_t state[8], const uint8_t *blocks, size_t block_count) {
    const uint8_t *block = blocks;

    for (size_t block_index = 0; block_index < block_count; ++block_index) {
        uint32_t w[64];

        for (size_t index = 0; index < 16; ++index) {
            const size_t position = index * 4;
            w[index] = ((uint32_t)block[position] << 24)
                | ((uint32_t)block[position + 1] << 16)
                | ((uint32_t)block[position + 2] << 8)
                | (uint32_t)block[position + 3];
        }
        for (size_t index = 16; index < 64; ++index) {
            const uint32_t x = w[index - 15];
            const uint32_t y = w[index - 2];
            const uint32_t sigma0 = rotate_right(x, 7) ^ rotate_right(x, 18) ^ (x >> 3);
            const uint32_t sigma1 = rotate_right(y, 17) ^ rotate_right(y, 19) ^ (y >> 10);
            w[index] = w[index - 16] + sigma0 + w[index - 7] + sigma1;
        }

        uint32_t a = state[0];
        uint32_t b = state[1];
        uint32_t c = state[2];
        uint32_t d = state[3];
        uint32_t e = state[4];
        uint32_t f = state[5];
        uint32_t g = state[6];
        uint32_t h = state[7];

        for (size_t index = 0; index < 64; ++index) {
            const uint32_t sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
            const uint32_t choose = (e & f) ^ (~e & g);
            const uint32_t temp1 = h + sum1 + choose + round_constants[index] + w[index];
            const uint32_t sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
            const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t temp2 = sum0 + majority;

            h = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }

        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
        state[5] += f;
        state[6] += g;
        state[7] += h;

        block += 64;
    }
}
