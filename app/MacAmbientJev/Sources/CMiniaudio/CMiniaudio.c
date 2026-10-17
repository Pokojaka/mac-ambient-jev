#include "include/CMiniaudio.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <io.h>
#define MA_ENABLE_WASAPI
#else
#include <sys/types.h>
#include <unistd.h>
#endif

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ATOMIC_MODERN_GCC
#include "include/miniaudio.h"

struct mja_resampler {
    ma_linear_resampler resampler;
    uint64_t latency;
};

struct mja_decoder {
    ma_vfs_callbacks vfs;
    int fd;
    ma_result ioResult;
    ma_decoder decoder;
    uint64_t length;
    uint32_t rate;
    uint32_t channels;
};

/* For miniaudio's even order-8 LPF, section j has Q_j = 1/(2 cos((2j+1)pi/16)),
   and DC delay 1/(2 Q_j tan(pi*cutoff/filterRate)). Thus C = sum(j=0..3) 1/Q_j
   = 2 sum(j=0..3) cos((2j+1)pi/16) = sum(k=0..7) sin((2k+1)pi/16). */
static const double mja_butterworth8_dc_group_delay = 5.1258308954830127;
static const double mja_lpf_nyquist_factor = 0.95;

static mja_decoder *mja_decoder_from_vfs(ma_vfs *vfs)
{
    return (mja_decoder *)vfs;
}

static ma_result mja_decoder_vfs_open(ma_vfs *vfs, const char *path, ma_uint32 mode, ma_vfs_file *file)
{
    if (file != NULL) {
        *file = NULL;
    }
    if (vfs == NULL || path == NULL || file == NULL) {
        return MA_INVALID_ARGS;
    }
    if (strcmp(path, "mja-borrowed-fd") != 0 || mode != MA_OPEN_MODE_READ) {
        return MA_INVALID_FILE;
    }

    *file = (ma_handle)vfs;
    return MA_SUCCESS;
}

static ma_result mja_decoder_vfs_close(ma_vfs *vfs, ma_vfs_file file)
{
    if (vfs == NULL || file != (ma_handle)vfs) {
        return MA_INVALID_ARGS;
    }
    return MA_SUCCESS;
}

static ma_result mja_decoder_vfs_read(ma_vfs *vfs, ma_vfs_file file, void *dst, size_t size, size_t *bytesRead)
{
    mja_decoder *decoder;
    size_t boundedSize;
#if defined(_WIN32)
    int result;
#else
    ssize_t result;
#endif

    if (bytesRead != NULL) {
        *bytesRead = 0;
    }
    if (vfs == NULL || file != (ma_handle)vfs || (dst == NULL && size > 0)) {
        return MA_INVALID_ARGS;
    }

    decoder = mja_decoder_from_vfs(vfs);
    boundedSize = size > (size_t)INT_MAX ? (size_t)INT_MAX : size;
    if (boundedSize == 0) {
        return MA_SUCCESS;
    }

#if defined(_WIN32)
    result = _read(decoder->fd, dst, (unsigned int)boundedSize);
#else
    result = read(decoder->fd, dst, boundedSize);
#endif
    if (result < 0) {
        if (decoder->ioResult == MA_SUCCESS) {
            decoder->ioResult = MA_IO_ERROR;
        }
        return decoder->ioResult;
    }
    if (bytesRead != NULL) {
        *bytesRead = (size_t)result;
    }
    return MA_SUCCESS;
}

static ma_result mja_decoder_vfs_seek(ma_vfs *vfs, ma_vfs_file file, ma_int64 offset, ma_seek_origin origin)
{
    mja_decoder *decoder;
    int whence;
#if defined(_WIN32)
    __int64 result;
#else
    off_t result;
#endif

    if (vfs == NULL || file != (ma_handle)vfs) {
        return MA_INVALID_ARGS;
    }

    switch (origin) {
        case ma_seek_origin_start:
            whence = SEEK_SET;
            break;
        case ma_seek_origin_current:
            whence = SEEK_CUR;
            break;
        case ma_seek_origin_end:
            whence = SEEK_END;
            break;
        default:
            return MA_BAD_SEEK;
    }

    decoder = mja_decoder_from_vfs(vfs);
#if defined(_WIN32)
    result = _lseeki64(decoder->fd, (__int64)offset, whence);
#else
    result = lseek(decoder->fd, (off_t)offset, whence);
#endif
    if (result == -1) {
        if (decoder->ioResult == MA_SUCCESS) {
            decoder->ioResult = MA_BAD_SEEK;
        }
        return decoder->ioResult;
    }
    return MA_SUCCESS;
}

static ma_result mja_decoder_vfs_tell(ma_vfs *vfs, ma_vfs_file file, ma_int64 *cursor)
{
    mja_decoder *decoder;
#if defined(_WIN32)
    __int64 result;
#else
    off_t result;
#endif

    if (cursor == NULL || vfs == NULL || file != (ma_handle)vfs) {
        return MA_INVALID_ARGS;
    }

    decoder = mja_decoder_from_vfs(vfs);
#if defined(_WIN32)
    result = _lseeki64(decoder->fd, 0, SEEK_CUR);
#else
    result = lseek(decoder->fd, 0, SEEK_CUR);
#endif
    if (result < 0) {
        if (decoder->ioResult == MA_SUCCESS) {
            decoder->ioResult = MA_IO_ERROR;
        }
        return decoder->ioResult;
    }
    *cursor = (ma_int64)result;
    return MA_SUCCESS;
}

static ma_result mja_decoder_validate_wav_extent(mja_decoder *decoder)
{
    ma_vfs *vfs = (ma_vfs *)&decoder->vfs;
    ma_vfs_file file = (ma_vfs_file)decoder;
    uint8_t header[12];
    uint8_t chunkHeader[8];
    size_t totalBytesRead = 0;
    ma_int64 actualEnd;
    ma_result result;
    uint64_t physicalEnd;
    uint64_t position;
    uint64_t payloadPosition;
    uint64_t paddedChunkSize;
    uint32_t chunkSize;
    ma_bool32 littleEndian;

    result = decoder->vfs.onSeek(vfs, file, 0, ma_seek_origin_start);
    if (result != MA_SUCCESS) {
        return result;
    }

    while (totalBytesRead < sizeof(header)) {
        size_t bytesRead = 0;
        result = decoder->vfs.onRead(
            vfs,
            file,
            header + totalBytesRead,
            sizeof(header) - totalBytesRead,
            &bytesRead);
        if (result != MA_SUCCESS) {
            return result;
        }
        if (bytesRead == 0) {
            return MA_INVALID_FILE;
        }
        totalBytesRead += bytesRead;
    }

    if (memcmp(header, "RIFF", 4) == 0 && memcmp(header + 8, "WAVE", 4) == 0) {
        littleEndian = MA_TRUE;
    } else if (memcmp(header, "RIFX", 4) == 0 && memcmp(header + 8, "WAVE", 4) == 0) {
        littleEndian = MA_FALSE;
    } else {
        return decoder->vfs.onSeek(vfs, file, 0, ma_seek_origin_start);
    }

    result = decoder->vfs.onSeek(vfs, file, 0, ma_seek_origin_end);
    if (result != MA_SUCCESS) {
        return result;
    }
    result = decoder->vfs.onTell(vfs, file, &actualEnd);
    if (result != MA_SUCCESS) {
        return result;
    }
    if (actualEnd < (ma_int64)sizeof(header)) {
        return MA_INVALID_FILE;
    }

    physicalEnd = (uint64_t)actualEnd;
    position = sizeof(header);
    for (;;) {
        if (position > physicalEnd || physicalEnd - position < sizeof(chunkHeader)) {
            return MA_INVALID_FILE;
        }

        result = decoder->vfs.onSeek(vfs, file, (ma_int64)position, ma_seek_origin_start);
        if (result != MA_SUCCESS) {
            return result;
        }

        totalBytesRead = 0;
        while (totalBytesRead < sizeof(chunkHeader)) {
            size_t bytesRead = 0;
            result = decoder->vfs.onRead(
                vfs,
                file,
                chunkHeader + totalBytesRead,
                sizeof(chunkHeader) - totalBytesRead,
                &bytesRead);
            if (result != MA_SUCCESS) {
                return result;
            }
            if (bytesRead == 0) {
                return MA_INVALID_FILE;
            }
            totalBytesRead += bytesRead;
        }

        if (littleEndian) {
            chunkSize = (uint32_t)chunkHeader[4]
                      | ((uint32_t)chunkHeader[5] << 8)
                      | ((uint32_t)chunkHeader[6] << 16)
                      | ((uint32_t)chunkHeader[7] << 24);
        } else {
            chunkSize = ((uint32_t)chunkHeader[4] << 24)
                      | ((uint32_t)chunkHeader[5] << 16)
                      | ((uint32_t)chunkHeader[6] << 8)
                      | (uint32_t)chunkHeader[7];
        }
        payloadPosition = position + sizeof(chunkHeader);

        if (memcmp(chunkHeader, "data", 4) == 0) {
            if (chunkSize != UINT32_MAX && (uint64_t)chunkSize > physicalEnd - payloadPosition) {
                return MJA_DECODER_UNEXPECTED_EOF;
            }
            return decoder->vfs.onSeek(vfs, file, 0, ma_seek_origin_start);
        }

        paddedChunkSize = (uint64_t)chunkSize + (chunkSize & 1u);
        if (paddedChunkSize > physicalEnd - payloadPosition) {
            return MA_INVALID_FILE;
        }
        position = payloadPosition + paddedChunkSize;
    }
}

int32_t mja_resampler_create(uint32_t rate, mja_resampler **out)
{
    mja_resampler *resampler;
    ma_linear_resampler_config config;
    ma_result result;
    double filterRate;
    double cutoff;
    double ratio;
    double filterDelay;
    double outputDelay;
    double roundedLatency;

    if (out == NULL) {
        return MA_INVALID_ARGS;
    }
    *out = NULL;
    if (rate == 0) {
        return MA_INVALID_ARGS;
    }

    /* miniaudio 0.11.23's linear LPF uses max(rate, 16000) for its filter
       rate and min(rate, 16000)/2 times mja_lpf_nyquist_factor for its cutoff.
       With D = C/(2*tan(pi*cutoff/filterRate)), output delay is
       (1+D)*(16000/rate) when downsampling, otherwise 16000/rate + D;
       round to output frames with floor(outputDelay + 0.5). */
    filterRate = rate > 16000 ? (double)rate : 16000.0;
    cutoff = (rate < 16000 ? (double)rate : 16000.0) * 0.5 * mja_lpf_nyquist_factor;
    ratio = 16000.0 / (double)rate;
    filterDelay = mja_butterworth8_dc_group_delay / (2.0 * tan(acos(-1.0) * cutoff / filterRate));
    outputDelay = rate > 16000 ? (1.0 + filterDelay) * ratio : ratio + filterDelay;
    if (!isfinite(outputDelay) || outputDelay < 0.0) {
        return MA_INVALID_DATA;
    }
    roundedLatency = floor(outputDelay + 0.5);
    if (!isfinite(roundedLatency) || roundedLatency < 0.0 || roundedLatency >= ldexp(1.0, 64)) {
        return MA_INVALID_DATA;
    }

    resampler = (mja_resampler *)calloc(1, sizeof(*resampler));
    if (resampler == NULL) {
        return MA_OUT_OF_MEMORY;
    }
    resampler->latency = (uint64_t)roundedLatency;

    config = ma_linear_resampler_config_init(ma_format_f32, 1, rate, 16000);
    config.lpfOrder = MA_MAX_FILTER_ORDER;
    config.lpfNyquistFactor = mja_lpf_nyquist_factor;
    result = ma_linear_resampler_init(&config, NULL, &resampler->resampler);
    if (result != MA_SUCCESS) {
        free(resampler);
        return result;
    }

    *out = resampler;
    return MA_SUCCESS;
}

int32_t mja_resampler_process(mja_resampler *resampler, const float *input, uint64_t *inputFrames, float *output, uint64_t *outputFrames)
{
    ma_uint64 framesIn;
    ma_uint64 framesOut;
    ma_result result;

    if (resampler == NULL || inputFrames == NULL || outputFrames == NULL) {
        return MA_INVALID_ARGS;
    }
    if ((*inputFrames > 0 && input == NULL) || (*outputFrames > 0 && output == NULL)) {
        return MA_INVALID_ARGS;
    }
    if (*outputFrames == 0) {
        *inputFrames = 0;
        return MA_SUCCESS;
    }

    framesIn = (ma_uint64)*inputFrames;
    framesOut = (ma_uint64)*outputFrames;
    result = ma_linear_resampler_process_pcm_frames(&resampler->resampler, input, &framesIn, output, &framesOut);
    *inputFrames = (uint64_t)framesIn;
    *outputFrames = (uint64_t)framesOut;
    return result;
}

uint64_t mja_resampler_latency(mja_resampler *resampler)
{
    if (resampler == NULL) {
        return 0;
    }
    return resampler->latency;
}

void mja_resampler_destroy(mja_resampler *resampler)
{
    if (resampler == NULL) {
        return;
    }
    ma_linear_resampler_uninit(&resampler->resampler, NULL);
    free(resampler);
}

int32_t mja_decoder_create(int fd, mja_decoder_format format, mja_decoder **out, uint32_t *rate, uint32_t *channels, uint64_t *length)
{
    mja_decoder *decoder;
    ma_decoder_config config;
    ma_encoding_format encodingFormat;
    ma_format outputFormat;
    ma_uint32 outputChannels;
    ma_uint32 outputRate;
    ma_uint64 outputLength;
    ma_result result;
    ma_bool32 decoderInitialized;

    if (out == NULL) {
        return MA_INVALID_ARGS;
    }
    *out = NULL;
    if (rate != NULL) {
        *rate = 0;
    }
    if (channels != NULL) {
        *channels = 0;
    }
    if (length != NULL) {
        *length = 0;
    }
    if (fd < 0 || rate == NULL || channels == NULL || length == NULL) {
        return MA_INVALID_ARGS;
    }

    switch (format) {
        case MJA_DECODER_FORMAT_WAV:
            encodingFormat = ma_encoding_format_wav;
            break;
        case MJA_DECODER_FORMAT_FLAC:
            encodingFormat = ma_encoding_format_flac;
            break;
        case MJA_DECODER_FORMAT_MP3:
            encodingFormat = ma_encoding_format_mp3;
            break;
        default:
            return MA_INVALID_ARGS;
    }

    decoder = (mja_decoder *)calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        return MA_OUT_OF_MEMORY;
    }
    decoder->fd = fd;
    decoder->vfs.onOpen = mja_decoder_vfs_open;
    decoder->vfs.onClose = mja_decoder_vfs_close;
    decoder->vfs.onRead = mja_decoder_vfs_read;
    decoder->vfs.onSeek = mja_decoder_vfs_seek;
    decoder->vfs.onTell = mja_decoder_vfs_tell;

    config = ma_decoder_config_init(ma_format_f32, 0, 0);
    config.encodingFormat = encodingFormat;
    if (format == MJA_DECODER_FORMAT_WAV) {
        result = mja_decoder_validate_wav_extent(decoder);
        if (result != MA_SUCCESS) {
            free(decoder);
            return result;
        }
    }
    result = ma_decoder_init_vfs((ma_vfs *)&decoder->vfs, "mja-borrowed-fd", &config, &decoder->decoder);
    decoderInitialized = result == MA_SUCCESS;
    if (decoder->ioResult != MA_SUCCESS) {
        result = decoder->ioResult;
    }
    if (result != MA_SUCCESS) {
        if (decoderInitialized || (decoder->decoder.pBackend == NULL && decoder->decoder.ds.vtable != NULL)) {
            ma_decoder_uninit(&decoder->decoder);
        }
        free(decoder);
        return result;
    }

    result = ma_decoder_get_data_format(&decoder->decoder, &outputFormat, &outputChannels, &outputRate, NULL, 0);
    if (decoder->ioResult != MA_SUCCESS) {
        result = decoder->ioResult;
    }
    if (result != MA_SUCCESS) {
        ma_decoder_uninit(&decoder->decoder);
        free(decoder);
        return result;
    }
    if (outputFormat != ma_format_f32 || outputChannels == 0 || outputChannels > 254 || outputRate == 0) {
        ma_decoder_uninit(&decoder->decoder);
        free(decoder);
        return MA_INVALID_DATA;
    }

    result = ma_decoder_get_length_in_pcm_frames(&decoder->decoder, &outputLength);
    if (decoder->ioResult != MA_SUCCESS) {
        result = decoder->ioResult;
    }
    if (result != MA_SUCCESS) {
        ma_decoder_uninit(&decoder->decoder);
        free(decoder);
        return result;
    }
    if (outputLength == 0) {
        ma_decoder_uninit(&decoder->decoder);
        free(decoder);
        return format == MJA_DECODER_FORMAT_FLAC
             ? MJA_DECODER_MISSING_TOTAL_SAMPLE_COUNT
             : MA_INVALID_DATA;
    }

    decoder->length = (uint64_t)outputLength;
    decoder->rate = (uint32_t)outputRate;
    decoder->channels = (uint32_t)outputChannels;
    *rate = decoder->rate;
    *channels = decoder->channels;
    *length = decoder->length;
    *out = decoder;
    return MA_SUCCESS;
}

int32_t mja_decoder_read(mja_decoder *decoder, float *out, uint64_t capacity, uint64_t *read)
{
    ma_uint64 framesRead = 0;
    ma_uint64 cursor = 0;
    ma_int64 filePosition;
    ma_int64 physicalEnd;
    ma_result result;
    ma_result cursorResult;
    ma_result fileResult;
    ma_result restoreResult;

    if (read == NULL) {
        return MA_INVALID_ARGS;
    }
    *read = 0;
    if (decoder == NULL || (capacity > 0 && out == NULL)) {
        return MA_INVALID_ARGS;
    }
    if (decoder->ioResult != MA_SUCCESS) {
        return decoder->ioResult;
    }
    if (capacity == 0) {
        return MA_SUCCESS;
    }

    result = ma_decoder_read_pcm_frames(&decoder->decoder, out, (ma_uint64)capacity, &framesRead);
    if (decoder->ioResult != MA_SUCCESS) {
        *read = 0;
        return decoder->ioResult;
    }
    *read = (uint64_t)framesRead;
    if (result == MA_AT_END) {
        cursorResult = ma_decoder_get_cursor_in_pcm_frames(&decoder->decoder, &cursor);
        if (decoder->ioResult != MA_SUCCESS) {
            *read = 0;
            return decoder->ioResult;
        }
        if (cursorResult != MA_SUCCESS) {
            *read = 0;
            return cursorResult;
        }
        if (cursor < decoder->length) {
            *read = 0;
            fileResult = decoder->vfs.onTell(
                (ma_vfs *)&decoder->vfs,
                (ma_vfs_file)decoder,
                &filePosition);
            if (decoder->ioResult != MA_SUCCESS) {
                return decoder->ioResult;
            }
            if (fileResult != MA_SUCCESS) {
                return fileResult;
            }

            fileResult = decoder->vfs.onSeek(
                (ma_vfs *)&decoder->vfs,
                (ma_vfs_file)decoder,
                0,
                ma_seek_origin_end);
            if (fileResult != MA_SUCCESS) {
                restoreResult = decoder->vfs.onSeek(
                    (ma_vfs *)&decoder->vfs,
                    (ma_vfs_file)decoder,
                    filePosition,
                    ma_seek_origin_start);
                if (decoder->ioResult != MA_SUCCESS) {
                    return decoder->ioResult;
                }
                return restoreResult != MA_SUCCESS ? restoreResult : fileResult;
            }

            fileResult = decoder->vfs.onTell(
                (ma_vfs *)&decoder->vfs,
                (ma_vfs_file)decoder,
                &physicalEnd);
            restoreResult = decoder->vfs.onSeek(
                (ma_vfs *)&decoder->vfs,
                (ma_vfs_file)decoder,
                filePosition,
                ma_seek_origin_start);
            if (decoder->ioResult != MA_SUCCESS) {
                return decoder->ioResult;
            }
            if (restoreResult != MA_SUCCESS) {
                return restoreResult;
            }
            if (fileResult != MA_SUCCESS) {
                return fileResult;
            }
            return filePosition >= physicalEnd
                 ? MJA_DECODER_UNEXPECTED_EOF
                 : MA_INVALID_DATA;
        }
        if (cursor > decoder->length) {
            *read = 0;
            return MA_INVALID_DATA;
        }
        return MA_SUCCESS;
    }
    return result;
}

void mja_decoder_destroy(mja_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    ma_decoder_uninit(&decoder->decoder);
    free(decoder);
}
