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

#if defined(_WIN32)
typedef struct mja_capture mja_capture;
typedef struct mja_power_owner mja_power_owner;

typedef struct mja_capture_cleanup_errors {
    int32_t stop;
    int32_t environment;
    int32_t context;
} mja_capture_cleanup_errors;

typedef struct mja_power_errors {
    int32_t startup;
    int32_t wait;
    int32_t clear;
    int32_t cleanup;
} mja_power_errors;

typedef struct mja_capture_packet {
    const float *samples;
    uint32_t frame_count;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t flags;
    uint64_t device_position;
    uint64_t qpc_100ns;
    uint32_t packet_offset;
    uint32_t packet_frames;
} mja_capture_packet;

/* Native WASAPI AUDCLNT_BUFFERFLAGS bit values. */
enum {
    MJA_CAPTURE_PACKET_DISCONTINUITY = 1u,
    MJA_CAPTURE_PACKET_SILENT = 2u,
    MJA_CAPTURE_PACKET_TIMESTAMP_ERROR = 4u
};

typedef enum mja_capture_pcm_format {
    MJA_CAPTURE_PCM_U8 = 1,
    MJA_CAPTURE_PCM_S16 = 2,
    MJA_CAPTURE_PCM_S24 = 3,
    MJA_CAPTURE_PCM_S32 = 4,
    MJA_CAPTURE_PCM_F32 = 5
} mja_capture_pcm_format;

typedef void (*mja_capture_packet_fn)(void *user, const mja_capture_packet *packet);
typedef void (*mja_capture_health_fn)(void *user, uint64_t watermark_qpc_100ns, int32_t output_state, int32_t error);
typedef void (*mja_capture_device_fn)(void *user, const char *id, const char *name, int32_t is_default);

/* Converts one borrowed native packet into callbacks of at most 512 frames.
 * sample_rate must be positive, channels 1...254, packet_frames 1...65536,
 * and flags may contain only the three native packet bits above. native_samples
 * may be NULL only for a silent packet. scratch must hold at least
 * 512 * channels floats. device_position and qpc_100ns remain the original
 * packet coordinates; packet_offset identifies each fragment. Silent packets
 * emit NULL samples; the packet and converted sample storage are borrowed only
 * during each callback. */
int32_t mja_capture_convert_packet(
    mja_capture_pcm_format format,
    uint32_t sample_rate,
    uint32_t channels,
    const void *native_samples,
    uint32_t packet_frames,
    uint32_t flags,
    uint64_t device_position,
    uint64_t qpc_100ns,
    float *scratch,
    uint32_t scratch_sample_capacity,
    mja_capture_packet_fn callback,
    void *user);

/* All functions returning int32_t return zero on success and nonzero on error. */
/* loopback is 0 for capture endpoints and 1 for render endpoints. The callback's
 * id and name are borrowed until it returns; is_default is 0 or 1. */
int32_t mja_capture_enumerate(int32_t loopback, mja_capture_device_fn callback, void *user);

/*
 * loopback and select_default must each be 0 or 1. Selection is valid only as
 * select_default == 1 with endpoint_id == NULL, or select_default == 0 with a
 * nonempty endpoint_id. On success the caller owns *out. Packet samples are
 * borrowed and valid only during the packet callback; samples are interleaved
 * float audio. Packet frame counts, offsets, and device_position are measured
 * in audio frames; qpc_100ns and watermark_qpc_100ns use the QPC
 * 100-nanosecond units. device_position and qpc_100ns identify the native
 * packet's first frame. packet_offset is the frame offset within that packet
 * and packet_frames is that packet's total frame count. Packet and health callbacks are serial
 * on the native producer; they must not allocate or block. Health is emitted
 * after each drain-all pass; capture liveness must be checked independently.
 * output_state is -1 unknown, 0 idle, or 1 external output active. error is
 * zero when healthy, otherwise a raw HRESULT/Win32 error or custom negative
 * error. stop_join is a callback fence: it returns only after callbacks finish
 * and no further callback can begin. Destroy only after stop_join for a started
 * capture. cleanup_errors is required and zeroed on entry. It reports all
  * nonzero stop,
  * environment, and context cleanup results even when the primary result is
  * already nonzero. Every nonzero function result denotes an error.
 */
int32_t mja_capture_open(int32_t loopback, const char *endpoint_id, int32_t select_default, mja_capture_packet_fn packet_callback, mja_capture_health_fn health_callback, void *user, mja_capture **out, uint32_t *rate, uint32_t *channels, mja_capture_cleanup_errors *cleanup_errors);
int32_t mja_capture_start(mja_capture *capture);
int32_t mja_capture_stop_join(mja_capture *capture, mja_capture_cleanup_errors *cleanup_errors);
void mja_capture_destroy(mja_capture *capture);

/* endpoint_id must be nonempty. If capacity is insufficient, return nonzero
 * and set *count to the required count without returning a truncated list.
 * The list excludes the audio engine process and its descendants. */
int32_t mja_capture_output_pids(const char *endpoint_id, uint32_t *pids, uint32_t capacity, uint32_t *count);

/* One process of a process snapshot. */
typedef struct mja_process_info {
    uint32_t process_id;
    uint32_t parent_process_id;
} mja_process_info;

/* Selects the external audio sessions. session_pids were listed BEFORE processes was
 * snapshotted, so a session PID absent from processes has exited since the listing and can be
 * neither current_pid nor its descendant: it is skipped. PID 0 (system sounds, or a session
 * spanning several processes) is external. current_pid missing from processes is an error
 * (ERROR_NOT_FOUND). *external_count is the number of external PIDs; if it exceeds capacity,
 * nonzero is returned and nothing is truncated silently. */
int32_t mja_output_filter_external_pids(
    const uint32_t *session_pids, uint32_t session_count,
    const mja_process_info *processes, uint32_t process_count,
    uint32_t current_pid,
    uint32_t *external_pids, uint32_t capacity, uint32_t *external_count);

/* Values the environment thread publishes together. Readers take a consistent set without
 * retrying or failing: snapshot always returns the last published set. A NULL state yields
 * ERROR_INVALID_PARAMETER in *error. */
typedef struct mja_environment_state mja_environment_state;
int32_t mja_environment_state_create(mja_environment_state **out);
void mja_environment_state_destroy(mja_environment_state *state);
void mja_environment_state_publish(mja_environment_state *state, uint64_t observed_qpc_100ns, uint64_t published_qpc_100ns, int32_t output_state, int32_t error);
void mja_environment_state_snapshot(mja_environment_state *state, uint64_t *observed_qpc_100ns, uint64_t *published_qpc_100ns, int32_t *output_state, int32_t *error);

/* directory is a NUL-terminated UTF-16 path; available receives available
 * bytes. A nonzero result is the raw Win32 error from the failed API call. */
int32_t mja_capture_disk_free(const uint16_t *directory, uint64_t *available);

/* Acquire and release on the same dedicated owner thread. `errors` is required
 * and is zeroed on entry. The return value is the primary failure; callers must
 * also inspect every nonzero diagnostic field, including on failure. */
int32_t mja_power_acquire(mja_power_owner **out, mja_power_errors *errors);
int32_t mja_power_release(mja_power_owner *owner, mja_power_errors *errors);
#endif

#ifdef __cplusplus
}
#endif

#endif
