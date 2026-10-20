#ifndef MAC_AMBIENT_WINDOWS_AUDIO_H
#define MAC_AMBIENT_WINDOWS_AUDIO_H

#if !defined(_WIN32)
#error CWindowsAudio is available only on Windows
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mja_mf_decoder mja_mf_decoder;

/*
 * Create an AAC decoder from a borrowed, pinned CRT file descriptor.
 * isADTS must be 0 for an MP4 container or 1 for an ADTS AAC file.
 *
 * The decoder duplicates the descriptor's OS handle and reads from that handle.
 * The Source Reader operates on the pinned handle byte stream and never opens
 * a pathname.
 *
 * Returns S_OK on success or a failing HRESULT. On failure, *out is null and
 * *rate and *channels are zero. The caller keeps fd alive until this returns.
 */
int32_t mja_mf_decoder_create(int fd, int isADTS, mja_mf_decoder **out,
                              uint32_t *rate, uint32_t *channels);

/*
 * Read up to capacityFrames interleaved float frames. framesRead is zero at
 * EOF; EOS can accompany a final non-empty read. Calls must be serialized.
 * Returns S_OK or a failing HRESULT.
 */
int32_t mja_mf_decoder_read(mja_mf_decoder *decoder, float *output,
                            uint32_t capacityFrames, uint32_t *framesRead);

/* Stops and joins the decoder's dedicated Media Foundation worker thread. */
void mja_mf_decoder_destroy(mja_mf_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
