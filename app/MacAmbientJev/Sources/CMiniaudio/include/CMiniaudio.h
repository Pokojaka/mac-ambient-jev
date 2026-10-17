#ifndef MJA_CMINIAUDIO_H
#define MJA_CMINIAUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mja_resampler mja_resampler;
typedef struct mja_decoder mja_decoder;

typedef enum mja_decoder_format {
    MJA_DECODER_FORMAT_WAV = 1,
    MJA_DECODER_FORMAT_FLAC = 2,
    MJA_DECODER_FORMAT_MP3 = 3
} mja_decoder_format;

int32_t mja_resampler_create(uint32_t rate, mja_resampler **out);
int32_t mja_resampler_process(mja_resampler *resampler, const float *input, uint64_t *inputFrames, float *output, uint64_t *outputFrames);
/* Returns the nearest-integer output-frame DC group delay of the fixed LPF8 with a 0.95 Nyquist cutoff plus linear interpolation. */
uint64_t mja_resampler_latency(mja_resampler *resampler);
void mja_resampler_destroy(mja_resampler *resampler);

/* mja_decoder_create/read が返す終端エラー。miniaudio の結果値ではない。 */
enum {
    MJA_DECODER_UNEXPECTED_EOF = -10000,
    MJA_DECODER_MISSING_TOTAL_SAMPLE_COUNT = -10001
};

int32_t mja_decoder_create(int fd, mja_decoder_format format, mja_decoder **out, uint32_t *rate, uint32_t *channels, uint64_t *length);
int32_t mja_decoder_read(mja_decoder *decoder, float *out, uint64_t capacity, uint64_t *read);
void mja_decoder_destroy(mja_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
