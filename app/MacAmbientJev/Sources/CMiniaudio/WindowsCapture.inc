#if defined(_WIN32)

#define MJA_CAPTURE_PACKET_FRAMES 512u
#define MJA_CAPTURE_MAX_CHANNELS 254u
#define MJA_CAPTURE_MAX_PACKET_FRAMES 65536u
#define MJA_CAPTURE_MAX_PACKETS_PER_PASS 256u
#define MJA_CAPTURE_ENDPOINT_ID_CAPACITY 1024u
/* No completed environment poll for this long: polls run every 100 ms, so 1 s is ten cycles. */
#define MJA_CAPTURE_QPC_FRESHNESS_100NS UINT64_C(10000000)
#define MJA_CAPTURE_ERROR_INTERRUPTED ((int32_t)-12001)
#define MJA_CAPTURE_ERROR_DRAIN_LIMIT ((int32_t)-12002)
#define MJA_CAPTURE_ERROR_FORMAT_CHANGED ((int32_t)-12003)

struct mja_capture {
    ma_context context;
    ma_log log;
    ma_device device;
    int32_t context_initialized;
    int32_t log_initialized;
    int32_t device_initialized;
    int32_t joined;
    int32_t stop_result;
    mja_capture_cleanup_errors cleanup_errors;
    int32_t health_error_reported;
    ma_atomic_int32 first_error;
    ma_atomic_bool32 expected_stop;
    mja_capture_packet_fn packet_callback;
    mja_capture_health_fn health_callback;
    void *user;
    mja_capture_environment *environment;
    char endpoint_id[MJA_CAPTURE_ENDPOINT_ID_CAPACITY];
    ma_format sample_format;
    uint32_t sample_rate;
    uint32_t channels;
    uint64_t qpc_frequency;
    float *scratch;
};

static void mja_capture_log_drop(void *user, ma_uint32 level, const char *message)
{
    (void)user;
    (void)level;
    (void)message;
}

static ma_result mja_capture_context_init(ma_context *context, ma_log *log)
{
    const ma_backend backend[1] = {ma_backend_wasapi};
    ma_context_config config = ma_context_config_init();
    ma_result result;

    result = ma_log_init(NULL, log);
    if (result != MA_SUCCESS) {
        return result;
    }
#if defined(MA_DEBUG_OUTPUT)
    result = ma_log_unregister_callback(log, ma_log_callback_init(ma_log_callback_debug, NULL));
    if (result != MA_SUCCESS) {
        ma_log_uninit(log);
        return result;
    }
#endif
    result = ma_log_register_callback(log, ma_log_callback_init(mja_capture_log_drop, NULL));
    if (result != MA_SUCCESS) {
        ma_log_uninit(log);
        return result;
    }

    config.pLog = log;
    result = ma_context_init(backend, 1, &config, context);
    if (result != MA_SUCCESS) {
        ma_log_uninit(log);
    }
    return result;
}

static int32_t mja_capture_wasapi_id_to_utf8(const ma_wchar_win32 *wide_id, char *utf8_id, size_t capacity)
{
    size_t index;
    int required;
    int converted;
    DWORD error;

    if (wide_id == NULL || utf8_id == NULL || capacity == 0 || capacity > INT_MAX) {
        return MA_INVALID_ARGS;
    }
    for (index = 0; index < 64; ++index) {
        if (wide_id[index] == 0) {
            break;
        }
    }
    if (index == 0 || index == 64) {
        return MA_INVALID_DATA;
    }

    required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (LPCWCH)wide_id, -1, NULL, 0, NULL, NULL);
    if (required <= 0) {
        error = GetLastError();
        return error != ERROR_SUCCESS ? (int32_t)error : MA_INVALID_DATA;
    }
    if ((size_t)required > capacity) {
        return MA_OUT_OF_RANGE;
    }

    converted = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, (LPCWCH)wide_id, -1, utf8_id, (int)capacity, NULL, NULL);
    if (converted != required) {
        error = GetLastError();
        return error != ERROR_SUCCESS ? (int32_t)error : MA_INVALID_DATA;
    }
    return MA_SUCCESS;
}

static ma_result mja_capture_get_endpoint_infos(
    ma_context *context,
    int32_t loopback,
    ma_device_info **infos,
    ma_uint32 *info_count)
{
    ma_device_info *playback_infos = NULL;
    ma_device_info *capture_infos = NULL;
    ma_uint32 playback_count = 0;
    ma_uint32 capture_count = 0;
    ma_result result;

    result = ma_context_get_devices(context, &playback_infos, &playback_count, &capture_infos, &capture_count);
    if (result != MA_SUCCESS) {
        return result;
    }
    if (loopback) {
        *infos = playback_infos;
        *info_count = playback_count;
    } else {
        *infos = capture_infos;
        *info_count = capture_count;
    }
    if (*info_count > 0 && *infos == NULL) {
        return MA_INVALID_DATA;
    }
    return MA_SUCCESS;
}

static ma_result mja_capture_resolve_endpoint(
    ma_context *context,
    int32_t loopback,
    const char *requested_id,
    int32_t select_default,
    ma_device_id *resolved_id)
{
    ma_device_info *infos = NULL;
    ma_uint32 info_count = 0;
    ma_uint32 index;
    ma_uint32 match_count = 0;
    ma_uint32 default_count = 0;
    const ma_device_info *selected = NULL;
    ma_result result;

    result = mja_capture_get_endpoint_infos(context, loopback, &infos, &info_count);
    if (result != MA_SUCCESS) {
        return result;
    }

    for (index = 0; index < info_count; ++index) {
        char current_id[MJA_CAPTURE_ENDPOINT_ID_CAPACITY];
        result = (ma_result)mja_capture_wasapi_id_to_utf8(
            infos[index].id.wasapi,
            current_id,
            sizeof(current_id));
        if (result != MA_SUCCESS) {
            return result;
        }

        if (infos[index].isDefault) {
            default_count += 1;
            if (select_default) {
                selected = &infos[index];
                match_count += 1;
            }
        }
        if (!select_default && strcmp(current_id, requested_id) == 0) {
            selected = &infos[index];
            match_count += 1;
        }
    }

    if (select_default) {
        if (default_count != 1 || match_count != 1 || selected == NULL) {
            return default_count == 0 ? MA_NO_DEVICE : MA_INVALID_DATA;
        }
    } else if (match_count != 1 || selected == NULL) {
        return match_count == 0 ? MA_NO_DEVICE : MA_INVALID_DATA;
    }

    *resolved_id = selected->id;
    return MA_SUCCESS;
}

int32_t mja_capture_enumerate(int32_t loopback, mja_capture_device_fn callback, void *user)
{
    ma_context context;
    ma_log log;
    ma_device_info *infos = NULL;
    ma_uint32 info_count = 0;
    ma_uint32 index;
    ma_result result;
    int32_t context_initialized = 0;
    int32_t log_initialized = 0;

    if ((loopback != 0 && loopback != 1) || callback == NULL) {
        return MA_INVALID_ARGS;
    }

    result = mja_capture_context_init(&context, &log);
    if (result != MA_SUCCESS) {
        return result;
    }
    context_initialized = 1;
    log_initialized = 1;

    result = mja_capture_get_endpoint_infos(&context, loopback, &infos, &info_count);
    if (result == MA_SUCCESS) {
        for (index = 0; index < info_count; ++index) {
            char endpoint_id[MJA_CAPTURE_ENDPOINT_ID_CAPACITY];
            int32_t conversion_result = mja_capture_wasapi_id_to_utf8(
                infos[index].id.wasapi,
                endpoint_id,
                sizeof(endpoint_id));
            if (conversion_result != MA_SUCCESS) {
                result = (ma_result)conversion_result;
                break;
            }
            callback(user, endpoint_id, infos[index].name, infos[index].isDefault ? 1 : 0);
        }
    }

    if (context_initialized) {
        ma_context_uninit(&context);
    }
    if (log_initialized) {
        ma_log_uninit(&log);
    }
    return result;
}

static void mja_capture_latch_error(mja_capture *capture, int32_t error)
{
    int32_t expected = 0;
    if (capture != NULL && error != 0) {
        ma_atomic_compare_exchange_strong_i32(&capture->first_error.value, &expected, error);
    }
}

static int32_t mja_capture_first_error(mja_capture *capture)
{
    return ma_atomic_int32_get(&capture->first_error);
}

static int32_t mja_capture_fail(
    mja_capture *capture,
    int32_t error,
    uint64_t observed_qpc_100ns,
    int32_t output_state)
{
    int32_t first_error;
    if (error == 0) {
        error = MA_INVALID_DATA;
    }
    mja_capture_latch_error(capture, error);
    first_error = mja_capture_first_error(capture);
    if (!capture->health_error_reported) {
        capture->health_error_reported = 1;
        capture->health_callback(capture->user, observed_qpc_100ns, output_state, first_error);
    }
    return first_error;
}

static void mja_capture_data_callback(ma_device *device, void *output, const void *input, ma_uint32 frame_count)
{
    (void)device;
    (void)output;
    (void)input;
    (void)frame_count;
}

static void mja_capture_notification_callback(const ma_device_notification *notification)
{
    mja_capture *capture;
    if (notification == NULL || notification->pDevice == NULL) {
        return;
    }
    capture = (mja_capture *)notification->pDevice->pUserData;
    if (capture == NULL || ma_atomic_bool32_get(&capture->expected_stop)) {
        return;
    }

    if (notification->type == ma_device_notification_type_stopped ||
        notification->type == ma_device_notification_type_interruption_began ||
        notification->type == ma_device_notification_type_rerouted) {
        mja_capture_latch_error(capture, MJA_CAPTURE_ERROR_INTERRUPTED);
    }
}

static int32_t mja_capture_validate_device_format(mja_capture *capture, ma_device *device)
{
    if (capture == NULL || device == NULL || device->pUserData != capture ||
        !capture->device_initialized ||
        (device->type != ma_device_type_capture && device->type != ma_device_type_loopback) ||
        device->capture.internalFormat != capture->sample_format ||
        device->capture.format != capture->sample_format ||
        device->capture.internalChannels != capture->channels ||
        device->capture.channels != capture->channels ||
        device->capture.internalSampleRate != capture->sample_rate ||
        device->sampleRate != capture->sample_rate) {
        return MJA_CAPTURE_ERROR_FORMAT_CHANGED;
    }
    return MA_SUCCESS;
}

typedef struct mja_capture_conversion_context {
    mja_capture_pcm_format format;
    uint32_t sample_rate;
    uint32_t channels;
    float *scratch;
    uint32_t scratch_sample_capacity;
    mja_capture_packet_fn callback;
    void *user;
} mja_capture_conversion_context;

static size_t mja_capture_bytes_per_sample(mja_capture_pcm_format format)
{
    switch (format) {
        case MJA_CAPTURE_PCM_U8: return 1;
        case MJA_CAPTURE_PCM_S16: return 2;
        case MJA_CAPTURE_PCM_S24: return 3;
        case MJA_CAPTURE_PCM_S32:
        case MJA_CAPTURE_PCM_F32: return 4;
        default: return 0;
    }
}

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
    void *user)
{
    const BYTE *native_bytes = (const BYTE *)native_samples;
    const uint32_t known_flags = MJA_CAPTURE_PACKET_DISCONTINUITY |
                                 MJA_CAPTURE_PACKET_SILENT |
                                 MJA_CAPTURE_PACKET_TIMESTAMP_ERROR;
    const ma_bool32 is_silent = (flags & MJA_CAPTURE_PACKET_SILENT) != 0;
    const size_t bytes_per_sample = mja_capture_bytes_per_sample(format);
    uint32_t packet_offset = 0;

    if (sample_rate == 0 || channels == 0 || channels > MJA_CAPTURE_MAX_CHANNELS ||
        packet_frames == 0 || packet_frames > MJA_CAPTURE_MAX_PACKET_FRAMES ||
        bytes_per_sample == 0 || (flags & ~known_flags) != 0 ||
        scratch == NULL ||
        scratch_sample_capacity < MJA_CAPTURE_PACKET_FRAMES * channels ||
        callback == NULL || (!is_silent && native_samples == NULL)) {
        return MA_INVALID_ARGS;
    }

    while (packet_offset < packet_frames) {
        const uint32_t remaining_frames = packet_frames - packet_offset;
        const uint32_t chunk_frames = remaining_frames > MJA_CAPTURE_PACKET_FRAMES
                                    ? MJA_CAPTURE_PACKET_FRAMES
                                    : remaining_frames;
        const size_t first_sample = (size_t)packet_offset * channels;
        const size_t sample_count = (size_t)chunk_frames * channels;
        size_t sample_index;
        mja_capture_packet packet;

        if (is_silent) {
            packet.samples = NULL;
        } else {
            switch (format) {
                case MJA_CAPTURE_PCM_U8:
                    for (sample_index = 0; sample_index < sample_count; ++sample_index) {
                        scratch[sample_index] = ((float)native_bytes[first_sample + sample_index] - 128.0f) / 128.0f;
                    }
                    break;
                case MJA_CAPTURE_PCM_S16:
                    for (sample_index = 0; sample_index < sample_count; ++sample_index) {
                        int16_t sample;
                        memcpy(&sample, native_bytes + (first_sample + sample_index) * sizeof(sample), sizeof(sample));
                        scratch[sample_index] = (float)sample / 32768.0f;
                    }
                    break;
                case MJA_CAPTURE_PCM_S24:
                    for (sample_index = 0; sample_index < sample_count; ++sample_index) {
                        const size_t byte_index = (first_sample + sample_index) * 3u;
                        const uint32_t raw = (uint32_t)native_bytes[byte_index]
                                           | ((uint32_t)native_bytes[byte_index + 1] << 8)
                                           | ((uint32_t)native_bytes[byte_index + 2] << 16);
                        int32_t sample = (int32_t)(raw & 0x007FFFFFu);
                        if ((raw & 0x00800000u) != 0) {
                            sample -= 0x00800000;
                        }
                        scratch[sample_index] = (float)sample / 8388608.0f;
                    }
                    break;
                case MJA_CAPTURE_PCM_S32:
                    for (sample_index = 0; sample_index < sample_count; ++sample_index) {
                        int32_t sample;
                        memcpy(&sample, native_bytes + (first_sample + sample_index) * sizeof(sample), sizeof(sample));
                        scratch[sample_index] = (float)sample / 2147483648.0f;
                    }
                    break;
                case MJA_CAPTURE_PCM_F32:
                    for (sample_index = 0; sample_index < sample_count; ++sample_index) {
                        float sample;
                        memcpy(&sample, native_bytes + (first_sample + sample_index) * sizeof(sample), sizeof(sample));
                        if (!isfinite(sample)) {
                            return MA_INVALID_DATA;
                        }
                        scratch[sample_index] = sample;
                    }
                    break;
                default:
                    return MA_INVALID_ARGS;
            }
            packet.samples = scratch;
        }

        packet.frame_count = chunk_frames;
        packet.channels = channels;
        packet.sample_rate = sample_rate;
        packet.flags = flags;
        packet.device_position = device_position;
        packet.qpc_100ns = qpc_100ns;
        packet.packet_offset = packet_offset;
        packet.packet_frames = packet_frames;
        callback(user, &packet);
        packet_offset += chunk_frames;
    }
    return MA_SUCCESS;
}

static mja_capture_pcm_format mja_capture_public_pcm_format(ma_format format)
{
    switch (format) {
        case ma_format_u8: return MJA_CAPTURE_PCM_U8;
        case ma_format_s16: return MJA_CAPTURE_PCM_S16;
        case ma_format_s24: return MJA_CAPTURE_PCM_S24;
        case ma_format_s32: return MJA_CAPTURE_PCM_S32;
        case ma_format_f32: return MJA_CAPTURE_PCM_F32;
        default: return (mja_capture_pcm_format)0;
    }
}

static int32_t mja_capture_deliver_packet(
    mja_capture *capture,
    const BYTE *native_data,
    ma_uint32 packet_frames,
    DWORD native_flags,
    ma_uint64 device_position,
    ma_uint64 qpc_100ns)
{
    mja_capture_conversion_context conversion;

    conversion.format = mja_capture_public_pcm_format(capture->sample_format);
    conversion.sample_rate = capture->sample_rate;
    conversion.channels = capture->channels;
    conversion.scratch = capture->scratch;
    conversion.scratch_sample_capacity = MJA_CAPTURE_PACKET_FRAMES * capture->channels;
    conversion.callback = capture->packet_callback;
    conversion.user = capture->user;

    return mja_capture_convert_packet(
        conversion.format,
        conversion.sample_rate,
        conversion.channels,
        native_data,
        packet_frames,
        (uint32_t)native_flags,
        (uint64_t)device_position,
        (uint64_t)qpc_100ns,
        conversion.scratch,
        conversion.scratch_sample_capacity,
        conversion.callback,
        conversion.user);
}

static int32_t mja_capture_qpc_now_100ns(mja_capture *capture, uint64_t *now_100ns)
{
    LARGE_INTEGER counter;
    uint64_t ticks;
    uint64_t seconds;
    uint64_t remainder;
    uint64_t whole;
    uint64_t fraction;

    if (capture == NULL || now_100ns == NULL || capture->qpc_frequency == 0) {
        return MA_INVALID_DATA;
    }
    if (!QueryPerformanceCounter(&counter)) {
        DWORD error = GetLastError();
        return error != ERROR_SUCCESS ? (int32_t)error : MA_INVALID_DATA;
    }
    if (counter.QuadPart < 0) {
        return MA_INVALID_DATA;
    }

    ticks = (uint64_t)counter.QuadPart;
    seconds = ticks / capture->qpc_frequency;
    remainder = ticks % capture->qpc_frequency;
    if (seconds > UINT64_MAX / UINT64_C(10000000) ||
        remainder > UINT64_MAX / UINT64_C(10000000)) {
        return MA_OUT_OF_RANGE;
    }
    whole = seconds * UINT64_C(10000000);
    fraction = (remainder * UINT64_C(10000000)) / capture->qpc_frequency;
    if (whole > UINT64_MAX - fraction) {
        return MA_OUT_OF_RANGE;
    }
    *now_100ns = whole + fraction;
    return MA_SUCCESS;
}

static int32_t mja_capture_packet_read(void *opaque_device, uint32_t *frames_read)
{
    ma_device *device = (ma_device *)opaque_device;
    mja_capture *capture;
    ma_IAudioCaptureClient *capture_client;
    uint64_t observed_qpc_100ns = 0;
    uint64_t published_qpc_100ns = 0;
    int32_t output_state = -1;
    int32_t environment_error = 0;
    int32_t result;
    ma_uint32 packets_read = 0;

    if (frames_read == NULL) {
        return MA_INVALID_ARGS;
    }
    *frames_read = 0;
    if (device == NULL) {
        return MA_INVALID_ARGS;
    }
    capture = (mja_capture *)device->pUserData;
    if (capture == NULL || !capture->device_initialized) {
        return MA_INVALID_OPERATION;
    }

    result = mja_capture_validate_device_format(capture, device);
    if (result != MA_SUCCESS) {
        return mja_capture_fail(capture, result, 0, -1);
    }

    result = mja_capture_first_error(capture);
    if (result != 0) {
        return mja_capture_fail(capture, result, 0, -1);
    }

    if (ma_device_get_state(device) != ma_device_state_started) {
        if (ma_atomic_bool32_get(&capture->expected_stop)) {
            return MA_SUCCESS;
        }
        return mja_capture_fail(capture, MJA_CAPTURE_ERROR_INTERRUPTED, 0, -1);
    }
    if (capture->environment == NULL) {
        return mja_capture_fail(capture, MA_INVALID_OPERATION, 0, -1);
    }

    mja_capture_environment_snapshot(
        capture->environment,
        &observed_qpc_100ns,
        &published_qpc_100ns,
        &output_state,
        &environment_error);

    capture_client = (ma_IAudioCaptureClient *)device->wasapi.pCaptureClient;
    if (capture_client == NULL) {
        return mja_capture_fail(capture, MA_INVALID_OPERATION, observed_qpc_100ns, output_state);
    }

    for (;;) {
        BYTE *native_data = NULL;
        ma_uint32 packet_frames = 0;
        DWORD native_flags = 0;
        ma_uint64 device_position = 0;
        ma_uint64 qpc_100ns = 0;
        HRESULT hr = ma_IAudioCaptureClient_GetBuffer(
            capture_client,
            &native_data,
            &packet_frames,
            &native_flags,
            &device_position,
            &qpc_100ns);
        int32_t packet_error = MA_SUCCESS;
        HRESULT release_hr;

        if (hr == MA_AUDCLNT_S_BUFFER_EMPTY) {
            break;
        }
        if (hr != S_OK) {
            return mja_capture_fail(capture, (int32_t)hr, observed_qpc_100ns, output_state);
        }

        if (packet_frames == 0) {
            packet_error = MA_INVALID_DATA;
        } else if (packet_frames > MJA_CAPTURE_MAX_PACKET_FRAMES) {
            packet_error = MA_OUT_OF_RANGE;
        } else if (packets_read >= MJA_CAPTURE_MAX_PACKETS_PER_PASS) {
            packet_error = MJA_CAPTURE_ERROR_DRAIN_LIMIT;
        } else {
            packets_read += 1;
            packet_error = mja_capture_deliver_packet(
                capture,
                native_data,
                packet_frames,
                native_flags,
                device_position,
                qpc_100ns);
        }

        release_hr = ma_IAudioCaptureClient_ReleaseBuffer(capture_client, packet_frames);
        if (FAILED(release_hr)) {
            return mja_capture_fail(capture, (int32_t)release_hr, observed_qpc_100ns, output_state);
        }
        if (packet_error != MA_SUCCESS) {
            return mja_capture_fail(capture, packet_error, observed_qpc_100ns, output_state);
        }
        result = mja_capture_first_error(capture);
        if (result != 0) {
            return mja_capture_fail(capture, result, observed_qpc_100ns, output_state);
        }
    }

    if (environment_error != 0) {
        return mja_capture_fail(capture, environment_error, observed_qpc_100ns, output_state);
    }

    result = mja_capture_first_error(capture);
    if (result != 0) {
        return mja_capture_fail(capture, result, observed_qpc_100ns, output_state);
    }

    if (output_state != 0 && output_state != 1) {
        return mja_capture_fail(capture, MA_INVALID_DATA, observed_qpc_100ns, output_state);
    }
    if (observed_qpc_100ns == 0) {
        return mja_capture_fail(capture, MA_INVALID_DATA, observed_qpc_100ns, output_state);
    }
    {
        uint64_t now_100ns = 0;
        result = mja_capture_qpc_now_100ns(capture, &now_100ns);
        if (result != MA_SUCCESS) {
            return mja_capture_fail(capture, result, observed_qpc_100ns, output_state);
        }
        if (published_qpc_100ns < observed_qpc_100ns || now_100ns < published_qpc_100ns) {
            return mja_capture_fail(capture, MA_INVALID_DATA, observed_qpc_100ns, output_state);
        }
        if (now_100ns - published_qpc_100ns > MJA_CAPTURE_QPC_FRESHNESS_100NS) {
            return mja_capture_fail(capture, MA_TIMEOUT, observed_qpc_100ns, output_state);
        }
    }
    result = mja_capture_first_error(capture);
    if (result != 0) {
        return mja_capture_fail(capture, result, observed_qpc_100ns, output_state);
    }
    capture->health_callback(capture->user, observed_qpc_100ns, output_state, 0);

    {
        DWORD wait_result = WaitForSingleObject((HANDLE)device->wasapi.hEventCapture, 10);
        if (wait_result == WAIT_FAILED) {
            DWORD error = GetLastError();
            return mja_capture_fail(
                capture,
                error != ERROR_SUCCESS ? (int32_t)error : MA_INVALID_OPERATION,
                observed_qpc_100ns,
                output_state);
        }
        if (wait_result != WAIT_OBJECT_0 && wait_result != WAIT_TIMEOUT) {
            return mja_capture_fail(capture, MA_INVALID_OPERATION, observed_qpc_100ns, output_state);
        }
    }

    return MA_SUCCESS;
}

static void mja_capture_dispose_partial(
    mja_capture *capture,
    mja_capture_cleanup_errors *cleanup_errors)
{
    if (capture == NULL) {
        return;
    }
    ma_atomic_bool32_set(&capture->expected_stop, MA_TRUE);
    if (capture->device_initialized) {
        ma_result stop_result = ma_device_stop(&capture->device);
        if (stop_result != MA_SUCCESS) {
            cleanup_errors->stop = (int32_t)stop_result;
        }
        ma_device_uninit(&capture->device);
        capture->device_initialized = 0;
    }
    if (capture->environment != NULL) {
        int32_t environment_result = mja_capture_environment_destroy(capture->environment);
        if (environment_result != 0) {
            cleanup_errors->environment = environment_result;
        }
        capture->environment = NULL;
    }
    if (capture->context_initialized) {
        ma_result context_result = ma_context_uninit(&capture->context);
        if (context_result != MA_SUCCESS) {
            cleanup_errors->context = (int32_t)context_result;
        }
        capture->context_initialized = 0;
    }
    if (capture->log_initialized) {
        ma_log_uninit(&capture->log);
        capture->log_initialized = 0;
    }
    free(capture->scratch);
    free(capture);
}

int32_t mja_capture_open(
    int32_t loopback,
    const char *endpoint_id,
    int32_t select_default,
    mja_capture_packet_fn packet_callback,
    mja_capture_health_fn health_callback,
    void *user,
    mja_capture **out,
    uint32_t *rate,
    uint32_t *channels,
    mja_capture_cleanup_errors *cleanup_errors)
{
    mja_capture *capture;
    ma_device_id resolved_id;
    ma_device_config config;
    char actual_endpoint_id[MJA_CAPTURE_ENDPOINT_ID_CAPACITY];
    LARGE_INTEGER qpc_frequency;
    ma_result result;
    int32_t native_id_result;

    if (rate != NULL) {
        *rate = 0;
    }
    if (channels != NULL) {
        *channels = 0;
    }
    if (out != NULL) {
        *out = NULL;
    }
    if (cleanup_errors == NULL || out == NULL) {
        return MA_INVALID_ARGS;
    }
    memset(cleanup_errors, 0, sizeof(*cleanup_errors));
    if ((loopback != 0 && loopback != 1) ||
        (select_default != 0 && select_default != 1) ||
        (select_default == 1 && endpoint_id != NULL) ||
        (select_default == 0 && (endpoint_id == NULL || endpoint_id[0] == '\0')) ||
        packet_callback == NULL || health_callback == NULL || rate == NULL || channels == NULL) {
        return MA_INVALID_ARGS;
    }

    capture = (mja_capture *)calloc(1, sizeof(*capture));
    if (capture == NULL) {
        return MA_OUT_OF_MEMORY;
    }
    capture->scratch = (float *)malloc((size_t)MJA_CAPTURE_PACKET_FRAMES * MJA_CAPTURE_MAX_CHANNELS * sizeof(float));
    if (capture->scratch == NULL) {
        free(capture);
        return MA_OUT_OF_MEMORY;
    }
    capture->packet_callback = packet_callback;
    capture->health_callback = health_callback;
    capture->user = user;
    ma_atomic_int32_set(&capture->first_error, 0);
    ma_atomic_bool32_set(&capture->expected_stop, MA_FALSE);

    result = mja_capture_context_init(&capture->context, &capture->log);
    if (result != MA_SUCCESS) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return result;
    }
    capture->context_initialized = 1;
    capture->log_initialized = 1;

    result = mja_capture_resolve_endpoint(
        &capture->context,
        loopback,
        endpoint_id,
        select_default,
        &resolved_id);
    if (result != MA_SUCCESS) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return result;
    }

    config = ma_device_config_init(loopback ? ma_device_type_loopback : ma_device_type_capture);
    config.sampleRate = 0;
    config.capture.pDeviceID = &resolved_id;
    config.capture.format = ma_format_unknown;
    config.capture.channels = 0;
    config.capture.shareMode = ma_share_mode_shared;
    config.playback.shareMode = ma_share_mode_shared;
    config.noFixedSizedCallback = MA_TRUE;
    config.dataCallback = mja_capture_data_callback;
    config.notificationCallback = mja_capture_notification_callback;
    config.pUserData = capture;
    config.wasapi.noAutoConvertSRC = MA_TRUE;
    config.wasapi.noAutoStreamRouting = MA_TRUE;
    config.wasapi.noHardwareOffloading = MA_TRUE;

    result = ma_device_init(&capture->context, &config, &capture->device);
    if (result != MA_SUCCESS) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return result;
    }
    capture->device_initialized = 1;

    if (capture->device.type != (loopback ? ma_device_type_loopback : ma_device_type_capture) ||
        capture->device.capture.internalChannels == 0 ||
        capture->device.capture.internalChannels > MJA_CAPTURE_MAX_CHANNELS ||
        capture->device.capture.internalSampleRate == 0 ||
        capture->device.capture.channels != capture->device.capture.internalChannels ||
        capture->device.sampleRate != capture->device.capture.internalSampleRate ||
        capture->device.capture.format != capture->device.capture.internalFormat ||
        (capture->device.capture.internalFormat != ma_format_u8 &&
         capture->device.capture.internalFormat != ma_format_s16 &&
         capture->device.capture.internalFormat != ma_format_s24 &&
         capture->device.capture.internalFormat != ma_format_s32 &&
         capture->device.capture.internalFormat != ma_format_f32)) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return MA_INVALID_DATA;
    }

    native_id_result = mja_capture_wasapi_id_to_utf8(
        capture->device.capture.id.wasapi,
        actual_endpoint_id,
        sizeof(actual_endpoint_id));
    if (native_id_result != MA_SUCCESS ||
        !ma_device_id_equal(&resolved_id, &capture->device.capture.id)) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return native_id_result != MA_SUCCESS ? native_id_result : MA_NO_DEVICE;
    }
    if (select_default == 0 && strcmp(actual_endpoint_id, endpoint_id) != 0) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return MA_NO_DEVICE;
    }
    memcpy(capture->endpoint_id, actual_endpoint_id, strlen(actual_endpoint_id) + 1);

    capture->sample_format = capture->device.capture.internalFormat;
    capture->sample_rate = capture->device.capture.internalSampleRate;
    capture->channels = capture->device.capture.internalChannels;

    if (!QueryPerformanceFrequency(&qpc_frequency)) {
        DWORD error = GetLastError();
        mja_capture_dispose_partial(capture, cleanup_errors);
        return error != ERROR_SUCCESS ? (int32_t)error : MA_INVALID_DATA;
    }
    if (qpc_frequency.QuadPart <= 0) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return MA_INVALID_DATA;
    }
    capture->qpc_frequency = (uint64_t)qpc_frequency.QuadPart;

    result = (ma_result)mja_capture_environment_create(
        capture->endpoint_id,
        loopback,
        select_default,
        &capture->environment);
    if (result != MA_SUCCESS) {
        mja_capture_dispose_partial(capture, cleanup_errors);
        return result;
    }

    *rate = capture->sample_rate;
    *channels = capture->channels;
    *out = capture;
    return MA_SUCCESS;
}

int32_t mja_capture_start(mja_capture *capture)
{
    if (capture == NULL) {
        return MA_INVALID_ARGS;
    }
    if (!capture->device_initialized || capture->joined) {
        return MA_INVALID_OPERATION;
    }
    return ma_device_start(&capture->device);
}

int32_t mja_capture_stop_join(
    mja_capture *capture,
    mja_capture_cleanup_errors *cleanup_errors)
{
    int32_t primary_error;

    if (cleanup_errors == NULL) {
        return MA_INVALID_ARGS;
    }
    memset(cleanup_errors, 0, sizeof(*cleanup_errors));
    if (capture == NULL) {
        return MA_INVALID_ARGS;
    }
    if (capture->joined) {
        *cleanup_errors = capture->cleanup_errors;
        return capture->stop_result;
    }

    memset(&capture->cleanup_errors, 0, sizeof(capture->cleanup_errors));
    ma_atomic_bool32_set(&capture->expected_stop, MA_TRUE);
    primary_error = mja_capture_first_error(capture);

    if (capture->device_initialized) {
        ma_result stop_result = ma_device_stop(&capture->device);
        if (stop_result != MA_SUCCESS) {
            capture->cleanup_errors.stop = (int32_t)stop_result;
        }
        ma_device_uninit(&capture->device);
        capture->device_initialized = 0;
        if (primary_error == 0) {
            primary_error = mja_capture_first_error(capture);
        }
        if (primary_error == 0 && stop_result != MA_SUCCESS) {
            primary_error = (int32_t)stop_result;
        }
    }

    if (capture->environment != NULL) {
        int32_t environment_result = mja_capture_environment_destroy(capture->environment);
        capture->environment = NULL;
        if (environment_result != 0) {
            capture->cleanup_errors.environment = environment_result;
            if (primary_error == 0) {
                primary_error = environment_result;
            }
        }
    }

    if (capture->context_initialized) {
        ma_result context_result = ma_context_uninit(&capture->context);
        capture->context_initialized = 0;
        if (context_result != MA_SUCCESS) {
            capture->cleanup_errors.context = (int32_t)context_result;
            if (primary_error == 0) {
                primary_error = (int32_t)context_result;
            }
        }
    }
    if (capture->log_initialized) {
        ma_log_uninit(&capture->log);
        capture->log_initialized = 0;
    }

    capture->stop_result = primary_error;
    capture->joined = 1;
    *cleanup_errors = capture->cleanup_errors;
    return capture->stop_result;
}

void mja_capture_destroy(mja_capture *capture)
{
    if (capture == NULL) {
        return;
    }
    if (!capture->joined) {
        MA_ASSERT(capture->joined);
        abort();
    }
    free(capture->scratch);
    free(capture);
}

#endif
