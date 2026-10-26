#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef CINTERFACE
#define CINTERFACE
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif

#include <windows.h>
#include <objbase.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int mja_test_interception_enabled;
static int mja_test_set_event_failure;
static DWORD mja_test_set_event_error;
static unsigned mja_test_set_event_calls;
static unsigned mja_test_wait_calls;
static unsigned mja_test_close_calls;

static BOOL WINAPI mja_test_SetEvent(HANDLE event)
{
    if (!mja_test_interception_enabled) return SetEvent(event);
    mja_test_set_event_calls++;
    if (mja_test_set_event_failure) {
        SetLastError(mja_test_set_event_error);
        return FALSE;
    }
    return TRUE;
}

static DWORD WINAPI mja_test_WaitForSingleObject(HANDLE handle, DWORD milliseconds)
{
    if (!mja_test_interception_enabled) return WaitForSingleObject(handle, milliseconds);
    mja_test_wait_calls++;
    SetLastError(ERROR_INVALID_HANDLE);
    return WAIT_FAILED;
}

static BOOL WINAPI mja_test_CloseHandle(HANDLE handle)
{
    if (!mja_test_interception_enabled) return CloseHandle(handle);
    mja_test_close_calls++;
    SetLastError(ERROR_INVALID_HANDLE);
    return FALSE;
}

static HRESULT STDMETHODCALLTYPE mja_test_get_device(
    IMMDeviceEnumerator *self, LPCWSTR endpoint_id, IMMDevice **device);
static HRESULT STDMETHODCALLTYPE mja_test_get_device_state(IMMDevice *self, DWORD *state);
static HRESULT STDMETHODCALLTYPE mja_test_activate(
    IMMDevice *self, REFIID interface_id, DWORD class_context,
    PROPVARIANT *activation_parameters, void **interface_out);
static ULONG STDMETHODCALLTYPE mja_test_release_device(IMMDevice *self);
static HRESULT STDMETHODCALLTYPE mja_test_get_session_enumerator(
    IAudioSessionManager2 *self, IAudioSessionEnumerator **session_enumerator);
static HRESULT STDMETHODCALLTYPE mja_test_get_session_count(
    IAudioSessionEnumerator *self, int *session_count);
static ULONG STDMETHODCALLTYPE mja_test_release_session_enumerator(IAudioSessionEnumerator *self);
static ULONG STDMETHODCALLTYPE mja_test_release_session_manager(IAudioSessionManager2 *self);

#undef SetEvent
#define SetEvent mja_test_SetEvent
#undef WaitForSingleObject
#define WaitForSingleObject mja_test_WaitForSingleObject
#undef CloseHandle
#define CloseHandle mja_test_CloseHandle
#undef IMMDeviceEnumerator_GetDevice
#define IMMDeviceEnumerator_GetDevice(self, endpoint_id, device) \
    mja_test_get_device((self), (endpoint_id), (device))
#undef IMMDevice_GetState
#define IMMDevice_GetState(self, state) mja_test_get_device_state((self), (state))
#undef IMMDevice_Activate
#define IMMDevice_Activate(self, interface_id, class_context, activation_parameters, interface_out) \
    mja_test_activate((self), (interface_id), (class_context), (activation_parameters), (interface_out))
#undef IMMDevice_Release
#define IMMDevice_Release(self) mja_test_release_device((self))
#undef IAudioSessionManager2_GetSessionEnumerator
#define IAudioSessionManager2_GetSessionEnumerator(self, session_enumerator) \
    mja_test_get_session_enumerator((self), (session_enumerator))
#undef IAudioSessionEnumerator_GetCount
#define IAudioSessionEnumerator_GetCount(self, session_count) \
    mja_test_get_session_count((self), (session_count))
#undef IAudioSessionEnumerator_Release
#define IAudioSessionEnumerator_Release(self) mja_test_release_session_enumerator((self))
#undef IAudioSessionManager2_Release
#define IAudioSessionManager2_Release(self) mja_test_release_session_manager((self))

#include "../../Sources/CMiniaudio/WindowsCaptureSafety.c"

static int mja_test_device_enumerator_storage;
static int mja_test_device_storage;
static int mja_test_manager_storage;
static int mja_test_session_enumerator_storage;
static DWORD mja_test_device_state;
static HRESULT mja_test_get_state_result;
static HRESULT mja_test_activate_result;
static HRESULT mja_test_session_enumerator_result;
static unsigned mja_test_get_device_calls;
static unsigned mja_test_get_state_calls;
static unsigned mja_test_activate_calls;
static unsigned mja_test_device_release_calls;
static unsigned mja_test_get_session_enumerator_calls;
static unsigned mja_test_session_enumerator_release_calls;
static unsigned mja_test_manager_release_calls;

static IMMDeviceEnumerator *mja_test_device_enumerator(void)
{
    return (IMMDeviceEnumerator *)(void *)&mja_test_device_enumerator_storage;
}

static IMMDevice *mja_test_device(void)
{
    return (IMMDevice *)(void *)&mja_test_device_storage;
}

static IAudioSessionManager2 *mja_test_manager(void)
{
    return (IAudioSessionManager2 *)(void *)&mja_test_manager_storage;
}

static IAudioSessionEnumerator *mja_test_session_enumerator(void)
{
    return (IAudioSessionEnumerator *)(void *)&mja_test_session_enumerator_storage;
}

static HRESULT STDMETHODCALLTYPE mja_test_get_device(
    IMMDeviceEnumerator *self, LPCWSTR endpoint_id, IMMDevice **device)
{
    (void)self;
    (void)endpoint_id;
    mja_test_get_device_calls++;
    *device = mja_test_device();
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE mja_test_get_device_state(IMMDevice *self, DWORD *state)
{
    (void)self;
    mja_test_get_state_calls++;
    if (SUCCEEDED(mja_test_get_state_result)) *state = mja_test_device_state;
    return mja_test_get_state_result;
}

static HRESULT STDMETHODCALLTYPE mja_test_activate(
    IMMDevice *self, REFIID interface_id, DWORD class_context,
    PROPVARIANT *activation_parameters, void **interface_out)
{
    (void)self;
    (void)interface_id;
    (void)class_context;
    (void)activation_parameters;
    mja_test_activate_calls++;
    if (SUCCEEDED(mja_test_activate_result)) *interface_out = mja_test_manager();
    return mja_test_activate_result;
}

static ULONG STDMETHODCALLTYPE mja_test_release_device(IMMDevice *self)
{
    (void)self;
    mja_test_device_release_calls++;
    return 1;
}

static HRESULT STDMETHODCALLTYPE mja_test_get_session_enumerator(
    IAudioSessionManager2 *self, IAudioSessionEnumerator **session_enumerator)
{
    (void)self;
    mja_test_get_session_enumerator_calls++;
    if (SUCCEEDED(mja_test_session_enumerator_result)) {
        *session_enumerator = mja_test_session_enumerator();
    }
    return mja_test_session_enumerator_result;
}

static HRESULT STDMETHODCALLTYPE mja_test_get_session_count(
    IAudioSessionEnumerator *self, int *session_count)
{
    (void)self;
    *session_count = 0;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE mja_test_release_session_enumerator(IAudioSessionEnumerator *self)
{
    (void)self;
    mja_test_session_enumerator_release_calls++;
    return 1;
}

static ULONG STDMETHODCALLTYPE mja_test_release_session_manager(IAudioSessionManager2 *self)
{
    (void)self;
    mja_test_manager_release_calls++;
    return 1;
}

static void mja_test_reset_fakes(void)
{
    mja_test_device_state = DEVICE_STATE_ACTIVE;
    mja_test_get_state_result = S_OK;
    mja_test_activate_result = S_OK;
    mja_test_session_enumerator_result = S_OK;
    mja_test_get_device_calls = 0;
    mja_test_get_state_calls = 0;
    mja_test_activate_calls = 0;
    mja_test_device_release_calls = 0;
    mja_test_get_session_enumerator_calls = 0;
    mja_test_session_enumerator_release_calls = 0;
    mja_test_manager_release_calls = 0;
}

static int mja_test_setup_environment(
    mja_capture_environment *environment, mja_environment_context *context)
{
    memset(environment, 0, sizeof(*environment));
    memset(context, 0, sizeof(*context));
    environment->endpoint_id = (WCHAR *)L"injected-endpoint";
    environment->loopback = 1;
    environment->watch_default = 0;
    context->environment = environment;
    context->enumerator = mja_test_device_enumerator();
    return QueryPerformanceFrequency(&context->frequency) ? 1 : 0;
}

static int mja_test_poll(mja_environment_context *context, int32_t expected_result)
{
    uint64_t qpc_100ns = 0;
    int32_t output_state = -1;
    int32_t result = mja_environment_poll(context, &qpc_100ns, &output_state);
    return result == expected_result;
}

static int mja_test_power_release_event_failure(void)
{
    mja_power_owner owner;
    mja_power_errors errors;
    HANDLE expected_thread = (HANDLE)(uintptr_t)1;
    HANDLE expected_ready = (HANDLE)(uintptr_t)2;
    HANDLE expected_release = (HANDLE)(uintptr_t)3;
    HANDLE expected_exit = (HANDLE)(uintptr_t)4;
    int32_t result;

    memset(&owner, 0, sizeof(owner));
    owner.thread = expected_thread;
    owner.ready_event = expected_ready;
    owner.release_event = expected_release;
    owner.exit_event = expected_exit;
    mja_test_interception_enabled = 1;
    mja_test_set_event_failure = 1;
    mja_test_set_event_error = ERROR_ACCESS_DENIED;
    mja_test_set_event_calls = 0;
    mja_test_wait_calls = 0;
    mja_test_close_calls = 0;

    result = mja_power_release(&owner, &errors);

    mja_test_interception_enabled = 0;
    mja_test_set_event_failure = 0;
    return result == (int32_t)ERROR_ACCESS_DENIED &&
        errors.cleanup == (int32_t)ERROR_ACCESS_DENIED &&
        errors.startup == 0 && errors.wait == 0 && errors.clear == 0 &&
        mja_test_set_event_calls == 1 && mja_test_wait_calls == 0 && mja_test_close_calls == 0 &&
        owner.thread == expected_thread && owner.ready_event == expected_ready &&
        owner.release_event == expected_release && owner.exit_event == expected_exit;
}

static int mja_test_power_success_cleanup(void)
{
    mja_power_owner *owner = NULL;
    mja_power_errors errors;
    int32_t acquire_result = mja_power_acquire(&owner, &errors);
    int32_t release_result;
    if (acquire_result != 0 || owner == NULL) return 0;
    release_result = mja_power_release(owner, &errors);
    return release_result == 0 && errors.startup == 0 && errors.wait == 0 &&
        errors.clear == 0 && errors.cleanup == 0;
}

static int mja_test_active_reuse_and_invalidation(void)
{
    mja_capture_environment environment;
    mja_environment_context context;
    int result;

    mja_test_reset_fakes();
    if (!mja_test_setup_environment(&environment, &context)) return 0;
    result = mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 1 && mja_test_get_session_enumerator_calls == 1 &&
        mja_test_device_release_calls == 1;
    result = result && mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 1 && mja_test_get_session_enumerator_calls == 2 &&
        mja_test_device_release_calls == 2;

    mja_test_device_state = DEVICE_STATE_DISABLED;
    result = result && mja_test_poll(&context, (int32_t)ERROR_DEVICE_NOT_CONNECTED) &&
        context.probe == NULL && mja_test_manager_release_calls == 1 &&
        mja_test_activate_calls == 1;

    mja_test_device_state = DEVICE_STATE_ACTIVE;
    result = result && mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 2 && mja_test_get_session_enumerator_calls == 3 &&
        mja_test_manager_release_calls == 1;
    mja_probe_destroy(context.probe);
    return result && mja_test_manager_release_calls == 2 && mja_test_get_device_calls == 4;
}

static int mja_test_get_state_failure_invalidation(void)
{
    mja_capture_environment environment;
    mja_environment_context context;
    const HRESULT state_error = (HRESULT)0x88890005L;
    int result;

    mja_test_reset_fakes();
    if (!mja_test_setup_environment(&environment, &context)) return 0;
    result = mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 1 && mja_test_get_session_enumerator_calls == 1;

    mja_test_get_state_result = state_error;
    result = result && mja_test_poll(&context, (int32_t)state_error) &&
        context.probe == NULL && mja_test_manager_release_calls == 1 &&
        mja_test_activate_calls == 1 && mja_test_get_session_enumerator_calls == 1;

    mja_test_get_state_result = S_OK;
    mja_test_device_state = DEVICE_STATE_ACTIVE;
    result = result && mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 2 && mja_test_get_session_enumerator_calls == 2;
    mja_probe_destroy(context.probe);
    return result && mja_test_manager_release_calls == 2;
}

static int mja_test_session_enumerator_error_is_not_retried(void)
{
    mja_capture_environment environment;
    mja_environment_context context;
    const HRESULT session_error = (HRESULT)0x88890004L;
    unsigned calls_before_error;
    int result;

    mja_test_reset_fakes();
    if (!mja_test_setup_environment(&environment, &context)) return 0;
    result = mja_test_poll(&context, 0) && context.probe != NULL &&
        mja_test_activate_calls == 1 && mja_test_get_session_enumerator_calls == 1;
    calls_before_error = mja_test_get_session_enumerator_calls;

    mja_test_session_enumerator_result = session_error;
    result = result && mja_test_poll(&context, (int32_t)session_error) &&
        context.probe != NULL && mja_test_activate_calls == 1 &&
        mja_test_get_session_enumerator_calls == calls_before_error + 1;
    mja_probe_destroy(context.probe);
    return result && mja_test_manager_release_calls == 1;
}

static int mja_test_environment_destroy_reports_device_loss(void)
{
    mja_capture_environment *environment =
        (mja_capture_environment *)calloc(1, sizeof(*environment));
    int32_t monitor_error = 0;
    int32_t result;

    if (environment == NULL) return 0;
    mja_environment_state_init(&environment->state);
    mja_environment_state_publish(&environment->state, 0, 0, -1, 1167);
    result = mja_capture_environment_destroy(environment, &monitor_error);
    return result == 0 && monitor_error == 1167;
}

static int mja_test_environment_destroy_reports_operational_error_separately(void)
{
    mja_capture_environment *environment =
        (mja_capture_environment *)calloc(1, sizeof(*environment));
    int32_t monitor_error = 0;
    int32_t result;

    if (environment == NULL) return 0;
    mja_environment_state_init(&environment->state);
    mja_environment_state_publish(&environment->state, 0, 0, -1, (int32_t)ERROR_ACCESS_DENIED);
    result = mja_capture_environment_destroy(environment, &monitor_error);
    return result == 0 && monitor_error == (int32_t)ERROR_ACCESS_DENIED;
}

static int mja_test_environment_destroy_preserves_teardown_error(void)
{
    mja_capture_environment *environment =
        (mja_capture_environment *)calloc(1, sizeof(*environment));
    int32_t monitor_error = 0;
    int32_t result;

    if (environment == NULL) return 0;
    mja_environment_state_init(&environment->state);
    mja_environment_state_publish(&environment->state, 0, 0, -1, 1167);
    environment->ready_event = (HANDLE)(uintptr_t)1;
    mja_test_interception_enabled = 1;
    mja_test_close_calls = 0;

    result = mja_capture_environment_destroy(environment, &monitor_error);

    mja_test_interception_enabled = 0;
    mja_test_set_event_failure = 0;
    return result == (int32_t)ERROR_INVALID_HANDLE && monitor_error == 1167 &&
        mja_test_close_calls == 1;
}

static int mja_test_environment_destroy_rejects_invalid_arguments(void)
{
    mja_capture_environment *environment;
    int32_t monitor_error = 123;
    int32_t result;

    result = mja_capture_environment_destroy(NULL, &monitor_error);
    if (result != (int32_t)ERROR_INVALID_PARAMETER || monitor_error != 0) return 0;
    if (mja_capture_environment_destroy(NULL, NULL) != (int32_t)ERROR_INVALID_PARAMETER) return 0;

    environment = (mja_capture_environment *)calloc(1, sizeof(*environment));
    if (environment == NULL) return 0;
    mja_environment_state_init(&environment->state);
    result = mja_capture_environment_destroy(environment, NULL);
    free(environment);
    return result == (int32_t)ERROR_INVALID_PARAMETER;
}

static int mja_test_run(const char *name, int (*test)(void))
{
    int passed = test();
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

int main(void)
{
    int passed = 1;
    passed &= mja_test_run("power release SetEvent failure", mja_test_power_release_event_failure);
    passed &= mja_test_run("power successful cleanup", mja_test_power_success_cleanup);
    passed &= mja_test_run("active probe reuse and invalidation", mja_test_active_reuse_and_invalidation);
    passed &= mja_test_run("GetState failure invalidation", mja_test_get_state_failure_invalidation);
    passed &= mja_test_run("session enumerator error propagation", mja_test_session_enumerator_error_is_not_retried);
    passed &= mja_test_run("environment destroy reports device loss", mja_test_environment_destroy_reports_device_loss);
    passed &= mja_test_run("environment destroy reports operational error", mja_test_environment_destroy_reports_operational_error_separately);
    passed &= mja_test_run("environment destroy preserves teardown error", mja_test_environment_destroy_preserves_teardown_error);
    passed &= mja_test_run("environment destroy rejects invalid arguments", mja_test_environment_destroy_rejects_invalid_arguments);
    return passed ? 0 : 1;
}
