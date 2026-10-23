#if defined(_WIN32)

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
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "include/CMiniaudio.h"
#include "WindowsCaptureEnvironment.h"

/* The Windows SDK GUID definitions for these interfaces are not linked by the Swift toolchain. */
static const GUID MJA_CLSID_MMDeviceEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const GUID MJA_IID_IMMDeviceEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const GUID MJA_IID_IAudioSessionManager2 = {0x77AA99A0, 0x1BD6, 0x484F, {0x8B, 0xC7, 0x2C, 0x65, 0x4C, 0x9A, 0x9B, 0x6F}};
static const GUID MJA_IID_IAudioSessionControl2 = {0xBFB7FF88, 0x7239, 0x4FC9, {0x8F, 0xA2, 0x07, 0xC9, 0x50, 0xBE, 0x9C, 0x6D}};

#define MJA_ERROR_POWER_ACQUIRE ((int32_t)-11001)
#define MJA_ERROR_POWER_CLEAR ((int32_t)-11002)
#define MJA_ERROR_DEFAULT_CHANGED ((int32_t)-11003)
#ifndef AUDCLNT_S_NO_SINGLE_PROCESS
#define AUDCLNT_S_NO_SINGLE_PROCESS ((HRESULT)0x0889000DL)
#endif
#define MJA_QPC_UNITS_PER_SECOND UINT64_C(10000000)
/* Environment polling uses a 100 ms observation interval. Ingress applies a 250 ms
 * health-fill grace; real PCM overlapping an already synthesized fill fails with .timestamp. */
#define MJA_ENVIRONMENT_POLL_MS 100u

struct mja_power_owner {
    HANDLE thread;
    HANDLE ready_event;
    HANDLE release_event;
    HANDLE exit_event;
    volatile LONG startup_error;
    volatile LONG wait_error;
    volatile LONG clear_error;
    volatile LONG exit_error;
};

/* The environment thread publishes four values that must be read together. A reader never
 * observes a half-written set and never retries: the critical section is a few stores. */
struct mja_environment_state {
    SRWLOCK lock;
    uint64_t observed_qpc_100ns;
    uint64_t published_qpc_100ns;
    int32_t output_state;
    int32_t error;
};

struct mja_capture_environment {
    HANDLE thread;
    HANDLE ready_event;
    HANDLE stop_event;
    WCHAR *endpoint_id;
    int32_t loopback;
    int32_t watch_default;
    volatile LONG stop_requested;
    volatile LONG startup_error;
    mja_environment_state state;
};

static int32_t mja_last_error_or(DWORD fallback)
{
    DWORD error = GetLastError();
    return (int32_t)(error == ERROR_SUCCESS ? fallback : error);
}

static int32_t mja_close_handle(HANDLE *handle)
{
    if (*handle == NULL || *handle == INVALID_HANDLE_VALUE) {
        *handle = NULL;
        return 0;
    }
    if (!CloseHandle(*handle)) {
        int32_t error = mja_last_error_or(ERROR_GEN_FAILURE);
        *handle = NULL;
        return error;
    }
    *handle = NULL;
    return 0;
}

static int mja_is_drive_letter(uint16_t value)
{
    return (value >= (uint16_t)'A' && value <= (uint16_t)'Z') ||
           (value >= (uint16_t)'a' && value <= (uint16_t)'z');
}

static int mja_is_path_separator(uint16_t value)
{
    return value == (uint16_t)'\\' || value == (uint16_t)'/';
}

static int mja_is_absolute_utf16_directory(const uint16_t *directory)
{
    size_t length = 0;
    if (directory == NULL || directory[0] == 0) {
        return 0;
    }
    while (directory[length] != 0) {
        length++;
    }
    if (length >= 3 && mja_is_drive_letter(directory[0]) && directory[1] == (uint16_t)':' &&
        mja_is_path_separator(directory[2])) {
        return 1;
    }
    if (length >= 5 && directory[0] == (uint16_t)'\\' && directory[1] == (uint16_t)'\\') {
        size_t index = 2;
        size_t server_start = index;
        while (index < length && !mja_is_path_separator(directory[index])) {
            index++;
        }
        if (index == server_start || index == length) {
            return 0;
        }
        while (index < length && mja_is_path_separator(directory[index])) {
            index++;
        }
        if (index == length) {
            return 0;
        }
        return 1;
    }
    return 0;
}

int32_t mja_capture_disk_free(const uint16_t *directory, uint64_t *available)
{
    DWORD attributes;
    ULARGE_INTEGER available_bytes;
    if (available == NULL || !mja_is_absolute_utf16_directory(directory)) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    attributes = GetFileAttributesW((LPCWSTR)directory);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        return mja_last_error_or(ERROR_GEN_FAILURE);
    }
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return (int32_t)ERROR_ACCESS_DENIED;
    }
    if (!GetDiskFreeSpaceExW((LPCWSTR)directory, &available_bytes, NULL, NULL)) {
        return mja_last_error_or(ERROR_GEN_FAILURE);
    }
    *available = available_bytes.QuadPart;
    return 0;
}

static DWORD WINAPI mja_power_thread(void *opaque)
{
    mja_power_owner *owner = (mja_power_owner *)opaque;
    EXECUTION_STATE state = SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
    int acquired = state != 0;
    int32_t startup_error = acquired ? 0 : MJA_ERROR_POWER_ACQUIRE;
    if (!acquired) {
        InterlockedExchange(&owner->startup_error, (LONG)startup_error);
    }
    if (!SetEvent(owner->ready_event)) {
        int32_t event_error = mja_last_error_or(ERROR_GEN_FAILURE);
        if (startup_error == 0) {
            startup_error = event_error;
            InterlockedExchange(&owner->startup_error, (LONG)event_error);
        }
    }
    if (startup_error == 0) {
        /* The release event is the only wake-up: acquire and release both run on this thread. */
        DWORD wait_result = WaitForSingleObject(owner->release_event, INFINITE);
        if (wait_result != WAIT_OBJECT_0) {
            InterlockedExchange(&owner->wait_error, (LONG)mja_last_error_or(ERROR_GEN_FAILURE));
        }
    }
    if (acquired && SetThreadExecutionState(ES_CONTINUOUS) == 0) {
        InterlockedExchange(&owner->clear_error, (LONG)MJA_ERROR_POWER_CLEAR);
    }
    if (!SetEvent(owner->exit_event)) {
        InterlockedExchange(&owner->exit_error, (LONG)mja_last_error_or(ERROR_GEN_FAILURE));
    }
    return 0;
}

static void mja_power_record_error(int32_t *category_error, int32_t error)
{
    if (*category_error == 0 && error != 0) {
        *category_error = error;
    }
}

static void mja_power_initialize_errors(mja_power_errors *errors)
{
    errors->startup = 0;
    errors->wait = 0;
    errors->clear = 0;
    errors->cleanup = 0;
}

static void mja_power_collect_owner_errors(mja_power_owner *owner, mja_power_errors *errors)
{
    mja_power_record_error(&errors->startup, (int32_t)InterlockedCompareExchange(&owner->startup_error, 0, 0));
    mja_power_record_error(&errors->wait, (int32_t)InterlockedCompareExchange(&owner->wait_error, 0, 0));
    mja_power_record_error(&errors->clear, (int32_t)InterlockedCompareExchange(&owner->clear_error, 0, 0));
    mja_power_record_error(&errors->cleanup, (int32_t)InterlockedCompareExchange(&owner->exit_error, 0, 0));
}

static int32_t mja_power_primary_error(int32_t primary_error, const mja_power_errors *errors)
{
    if (primary_error != 0) return primary_error;
    if (errors->startup != 0) return errors->startup;
    if (errors->wait != 0) return errors->wait;
    if (errors->clear != 0) return errors->clear;
    return errors->cleanup;
}

static int32_t mja_power_wait_and_dispose(mja_power_owner *owner, int32_t primary_error, mja_power_errors *errors)
{
    int32_t first_operation_error = primary_error;
    DWORD wait_result;
    int joined = owner->thread == NULL;

    if (owner->thread != NULL) {
        if (owner->release_event != NULL && !SetEvent(owner->release_event)) {
            int32_t event_error = mja_last_error_or(ERROR_GEN_FAILURE);
            mja_power_record_error(&errors->cleanup, event_error);
            if (first_operation_error == 0) first_operation_error = event_error;
        } else {
            wait_result = WaitForSingleObject(owner->thread, INFINITE);
            if (wait_result == WAIT_OBJECT_0) {
                joined = 1;
            } else {
                int32_t wait_error = mja_last_error_or(ERROR_GEN_FAILURE);
                mja_power_record_error(&errors->wait, wait_error);
                if (first_operation_error == 0) first_operation_error = wait_error;
            }
        }
    }

    /* A successful join makes worker results final before storage is disposed. */
    mja_power_collect_owner_errors(owner, errors);
    if (!joined) {
        /* Keep the owner and its handles alive if the worker could still use them. */
        return mja_power_primary_error(first_operation_error, errors);
    }

    {
        int32_t close_error = mja_close_handle(&owner->exit_event);
        mja_power_record_error(&errors->cleanup, close_error);
        close_error = mja_close_handle(&owner->release_event);
        mja_power_record_error(&errors->cleanup, close_error);
        close_error = mja_close_handle(&owner->ready_event);
        mja_power_record_error(&errors->cleanup, close_error);
        close_error = mja_close_handle(&owner->thread);
        mja_power_record_error(&errors->cleanup, close_error);
    }
    first_operation_error = mja_power_primary_error(first_operation_error, errors);
    free(owner);
    return first_operation_error;
}

int32_t mja_power_acquire(mja_power_owner **out, mja_power_errors *errors)
{
    mja_power_owner *owner;
    DWORD wait_result;
    int32_t error;
    if (errors == NULL) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    mja_power_initialize_errors(errors);
    if (out == NULL) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    *out = NULL;
    owner = (mja_power_owner *)calloc(1, sizeof(*owner));
    if (owner == NULL) {
        error = (int32_t)ERROR_NOT_ENOUGH_MEMORY;
        mja_power_record_error(&errors->startup, error);
        return error;
    }
    owner->ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (owner->ready_event == NULL) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
        mja_power_record_error(&errors->startup, error);
        return mja_power_wait_and_dispose(owner, error, errors);
    }
    owner->release_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (owner->release_event == NULL) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
        mja_power_record_error(&errors->startup, error);
        return mja_power_wait_and_dispose(owner, error, errors);
    }
    owner->exit_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (owner->exit_event == NULL) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
        mja_power_record_error(&errors->startup, error);
        return mja_power_wait_and_dispose(owner, error, errors);
    }
    owner->thread = CreateThread(NULL, 0, mja_power_thread, owner, 0, NULL);
    if (owner->thread == NULL) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
        mja_power_record_error(&errors->startup, error);
        return mja_power_wait_and_dispose(owner, error, errors);
    }
    {
        HANDLE startup_handles[2] = {owner->ready_event, owner->thread};
        wait_result = WaitForMultipleObjects(2, startup_handles, FALSE, INFINITE);
    }
    if (wait_result == WAIT_OBJECT_0) {
        error = (int32_t)InterlockedCompareExchange(&owner->startup_error, 0, 0);
    } else if (wait_result == WAIT_OBJECT_0 + 1) {
        error = (int32_t)InterlockedCompareExchange(&owner->startup_error, 0, 0);
        if (error == 0) error = (int32_t)ERROR_GEN_FAILURE;
    } else {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
    }
    if (error != 0) {
        mja_power_record_error(&errors->startup, error);
        return mja_power_wait_and_dispose(owner, error, errors);
    }
    *out = owner;
    return 0;
}

int32_t mja_power_release(mja_power_owner *owner, mja_power_errors *errors)
{
    int32_t error = 0;
    if (errors == NULL) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    mja_power_initialize_errors(errors);
    if (owner == NULL) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    return mja_power_wait_and_dispose(owner, error, errors);
}

static int32_t mja_utf8_to_wide(const char *utf8, WCHAR **wide_out)
{
    int required;
    int converted;
    WCHAR *wide;
    if (utf8 == NULL || utf8[0] == '\0' || wide_out == NULL) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    *wide_out = NULL;
    required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
    if (required <= 0) {
        return mja_last_error_or(ERROR_NO_UNICODE_TRANSLATION);
    }
    if ((size_t)required > SIZE_MAX / sizeof(WCHAR)) {
        return (int32_t)ERROR_ARITHMETIC_OVERFLOW;
    }
    wide = (WCHAR *)malloc((size_t)required * sizeof(WCHAR));
    if (wide == NULL) {
        return (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    }
    converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide, required);
    if (converted != required) {
        int32_t error = mja_last_error_or(ERROR_NO_UNICODE_TRANSLATION);
        free(wide);
        return error;
    }
    *wide_out = wide;
    return 0;
}

static void mja_environment_state_init(mja_environment_state *state)
{
    InitializeSRWLock(&state->lock);
    state->observed_qpc_100ns = 0;
    state->published_qpc_100ns = 0;
    state->output_state = -1;
    state->error = 0;
}

int32_t mja_environment_state_create(mja_environment_state **out)
{
    mja_environment_state *state;
    if (out == NULL) return (int32_t)ERROR_INVALID_PARAMETER;
    *out = NULL;
    state = (mja_environment_state *)calloc(1, sizeof(*state));
    if (state == NULL) return (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    mja_environment_state_init(state);
    *out = state;
    return 0;
}

void mja_environment_state_destroy(mja_environment_state *state)
{
    free(state);
}

void mja_environment_state_publish(mja_environment_state *state, uint64_t observed_qpc_100ns, uint64_t published_qpc_100ns, int32_t output_state, int32_t error)
{
    AcquireSRWLockExclusive(&state->lock);
    state->observed_qpc_100ns = observed_qpc_100ns;
    state->published_qpc_100ns = published_qpc_100ns;
    state->output_state = output_state;
    state->error = error;
    ReleaseSRWLockExclusive(&state->lock);
}

void mja_environment_state_snapshot(mja_environment_state *state, uint64_t *observed_qpc_100ns, uint64_t *published_qpc_100ns, int32_t *output_state, int32_t *error)
{
    uint64_t observed = 0;
    uint64_t published = 0;
    int32_t native_state = -1;
    int32_t native_error = (int32_t)ERROR_INVALID_PARAMETER;
    if (state != NULL) {
        AcquireSRWLockShared(&state->lock);
        observed = state->observed_qpc_100ns;
        published = state->published_qpc_100ns;
        native_state = state->output_state;
        native_error = state->error;
        ReleaseSRWLockShared(&state->lock);
    }
    if (observed_qpc_100ns != NULL) *observed_qpc_100ns = observed;
    if (published_qpc_100ns != NULL) *published_qpc_100ns = published;
    if (output_state != NULL) *output_state = native_state;
    if (error != NULL) *error = native_error;
}

void mja_capture_environment_snapshot(mja_capture_environment *environment, uint64_t *observed_qpc_100ns, uint64_t *published_qpc_100ns, int32_t *output_state, int32_t *error)
{
    mja_environment_state_snapshot(
        environment == NULL ? NULL : &environment->state,
        observed_qpc_100ns, published_qpc_100ns, output_state, error);
}

static int mja_compare_u32(const void *left, const void *right)
{
    uint32_t a = *(const uint32_t *)left;
    uint32_t b = *(const uint32_t *)right;
    return a < b ? -1 : (a > b ? 1 : 0);
}

/* process_id is the first member, so mja_compare_u32 orders and searches entries by PID. */
static int mja_find_process(const mja_process_info *sorted, uint32_t process_count, uint32_t process_id)
{
    const mja_process_info *found;
    if (process_count == 0) return -1;
    found = (const mja_process_info *)bsearch(&process_id, sorted, process_count, sizeof(*sorted), mja_compare_u32);
    return found == NULL ? -1 : (int)(found - sorted);
}

int32_t mja_output_filter_external_pids(
    const uint32_t *session_pids, uint32_t session_count,
    const mja_process_info *processes, uint32_t process_count,
    uint32_t current_pid,
    uint32_t *external_pids, uint32_t capacity, uint32_t *external_count)
{
    mja_process_info *sorted = NULL;
    int *first_child = NULL;
    int *next_sibling = NULL;
    int *queue = NULL;
    uint8_t *excluded = NULL;
    int32_t result = 0;
    uint32_t index;
    uint32_t count = 0;
    int current_index;

    if (external_count == NULL || (session_count != 0 && session_pids == NULL) ||
        (process_count != 0 && processes == NULL) || (capacity != 0 && external_pids == NULL)) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    *external_count = 0;
    if (process_count == 0 || (size_t)process_count > SIZE_MAX / sizeof(*sorted) || process_count > (uint32_t)INT_MAX) {
        return (int32_t)ERROR_NOT_FOUND;
    }
    sorted = (mja_process_info *)malloc((size_t)process_count * sizeof(*sorted));
    first_child = (int *)malloc((size_t)process_count * sizeof(int));
    next_sibling = (int *)malloc((size_t)process_count * sizeof(int));
    queue = (int *)malloc((size_t)process_count * sizeof(int));
    excluded = (uint8_t *)calloc(process_count, 1);
    if (sorted == NULL || first_child == NULL || next_sibling == NULL || queue == NULL || excluded == NULL) {
        result = (int32_t)ERROR_NOT_ENOUGH_MEMORY;
        goto done;
    }
    memcpy(sorted, processes, (size_t)process_count * sizeof(*sorted));
    qsort(sorted, process_count, sizeof(*sorted), mja_compare_u32);

    /* Our own process must be in the snapshot taken after the session listing. */
    current_index = mja_find_process(sorted, process_count, current_pid);
    if (current_index < 0) {
        result = (int32_t)ERROR_NOT_FOUND;
        goto done;
    }
    {
        uint32_t queue_head = 0;
        uint32_t queue_tail = 0;
        for (index = 0; index < process_count; index++) {
            first_child[index] = -1;
            next_sibling[index] = -1;
        }
        for (index = 0; index < process_count; index++) {
            uint32_t parent_id = sorted[index].parent_process_id;
            int parent_index = -1;
            if (parent_id != 0) parent_index = mja_find_process(sorted, process_count, parent_id);
            if (parent_index >= 0 && parent_index != (int)index) {
                next_sibling[index] = first_child[parent_index];
                first_child[parent_index] = (int)index;
            }
        }
        excluded[current_index] = 1;
        queue[queue_tail++] = current_index;
        while (queue_head < queue_tail) {
            int parent_index = queue[queue_head++];
            int child_index;
            for (child_index = first_child[parent_index]; child_index >= 0; child_index = next_sibling[child_index]) {
                if (!excluded[child_index]) {
                    excluded[child_index] = 1;
                    queue[queue_tail++] = child_index;
                }
            }
        }
    }

    for (index = 0; index < session_count; index++) {
        uint32_t process_id = session_pids[index];
        uint32_t seen;
        int duplicate = 0;
        if (process_id == current_pid) continue;
        if (process_id != 0) {
            int process_index = mja_find_process(sorted, process_count, process_id);
            /* The sessions were listed before the processes: a PID missing here exited after
             * the listing, so it is neither this process nor a descendant. */
            if (process_index < 0) continue;
            if (excluded[process_index]) continue;
        }
        for (seen = 0; seen < index; seen++) {
            if (session_pids[seen] == process_id) {
                duplicate = 1;
                break;
            }
        }
        if (duplicate) continue;
        if (count < capacity) external_pids[count] = process_id;
        count++;
    }
    *external_count = count;
    if (count > capacity) result = (int32_t)ERROR_INSUFFICIENT_BUFFER;
done:
    free(sorted);
    free(first_child);
    free(next_sibling);
    free(queue);
    free(excluded);
    return result;
}

static int32_t mja_process_snapshot(mja_process_info **out, uint32_t *out_count)
{
    HANDLE snapshot;
    PROCESSENTRY32W entry;
    mja_process_info *processes = NULL;
    uint32_t capacity = 0;
    uint32_t count = 0;
    int32_t error = 0;
    *out = NULL;
    *out_count = 0;
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return mja_last_error_or(ERROR_GEN_FAILURE);
    }
    memset(&entry, 0, sizeof(entry));
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot, &entry)) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
        goto done;
    }
    for (;;) {
        if (count == capacity) {
            uint32_t grown = capacity == 0 ? 512u : capacity * 2u;
            mja_process_info *resized = (mja_process_info *)realloc(processes, (size_t)grown * sizeof(*processes));
            if (resized == NULL) {
                error = (int32_t)ERROR_NOT_ENOUGH_MEMORY;
                goto done;
            }
            processes = resized;
            capacity = grown;
        }
        processes[count].process_id = (uint32_t)entry.th32ProcessID;
        processes[count].parent_process_id = (uint32_t)entry.th32ParentProcessID;
        count++;
        if (!Process32NextW(snapshot, &entry)) {
            DWORD last_error = GetLastError();
            if (last_error != ERROR_NO_MORE_FILES) {
                error = (int32_t)(last_error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : last_error);
            }
            break;
        }
    }
done:
    if (!CloseHandle(snapshot) && error == 0) {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
    }
    if (error != 0) {
        free(processes);
        return error;
    }
    *out = processes;
    *out_count = count;
    return 0;
}

/* Lists the active render sessions of one endpoint and classifies them. The session manager
 * lives as long as the probe. The process tree is rebuilt only when the set of active
 * session PIDs changes: a PID's parent never changes while the process lives. */
typedef struct mja_output_probe {
    IAudioSessionManager2 *session_manager;
    uint32_t capacity;
    uint32_t *scan;
    uint32_t scan_count;
    uint32_t *sessions;
    uint32_t session_count;
    uint32_t *external;
    uint32_t external_count;
    int primed;
} mja_output_probe;

static void mja_probe_destroy(mja_output_probe *probe)
{
    if (probe == NULL) return;
    if (probe->session_manager != NULL) IAudioSessionManager2_Release(probe->session_manager);
    free(probe->scan);
    free(probe->sessions);
    free(probe->external);
    free(probe);
}

static int32_t mja_probe_create(IMMDevice *device, mja_output_probe **out)
{
    mja_output_probe *probe = (mja_output_probe *)calloc(1, sizeof(*probe));
    HRESULT hr;
    *out = NULL;
    if (probe == NULL) return (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    hr = IMMDevice_Activate(device, &MJA_IID_IAudioSessionManager2, CLSCTX_ALL, NULL, (void **)&probe->session_manager);
    if (FAILED(hr)) {
        mja_probe_destroy(probe);
        return (int32_t)hr;
    }
    *out = probe;
    return 0;
}

static int32_t mja_probe_reserve(mja_output_probe *probe, uint32_t required)
{
    uint32_t *scan;
    uint32_t *sessions;
    uint32_t *external;
    uint32_t capacity;
    if (required <= probe->capacity) return 0;
    capacity = probe->capacity == 0 ? 32u : probe->capacity;
    while (capacity < required) capacity *= 2u;
    scan = (uint32_t *)realloc(probe->scan, (size_t)capacity * sizeof(uint32_t));
    if (scan != NULL) probe->scan = scan;
    sessions = (uint32_t *)realloc(probe->sessions, (size_t)capacity * sizeof(uint32_t));
    if (sessions != NULL) probe->sessions = sessions;
    external = (uint32_t *)realloc(probe->external, (size_t)capacity * sizeof(uint32_t));
    if (external != NULL) probe->external = external;
    if (scan == NULL || sessions == NULL || external == NULL) return (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    probe->capacity = capacity;
    return 0;
}

/* Fills probe->scan with the sorted, unique PIDs of active sessions. A session that spans
 * several processes cannot belong to this process alone, so it is reported as PID 0 (an
 * external session without a single owner), the same as the system-sounds session. */
static int32_t mja_probe_list_sessions(mja_output_probe *probe)
{
    IAudioSessionEnumerator *session_enumerator = NULL;
    HRESULT hr;
    int32_t result = 0;
    int session_count = 0;
    int session_index;
    uint32_t count = 0;
    uint32_t sorted_index;
    uint32_t unique = 0;

    hr = IAudioSessionManager2_GetSessionEnumerator(probe->session_manager, &session_enumerator);
    if (FAILED(hr)) return (int32_t)hr;
    hr = IAudioSessionEnumerator_GetCount(session_enumerator, &session_count);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto done;
    }
    if (session_count < 0) {
        result = (int32_t)ERROR_INVALID_DATA;
        goto done;
    }
    result = mja_probe_reserve(probe, (uint32_t)session_count);
    if (result != 0) goto done;
    for (session_index = 0; session_index < session_count; session_index++) {
        IAudioSessionControl *session_control = NULL;
        IAudioSessionControl2 *session_control2 = NULL;
        AudioSessionState state;
        DWORD process_id = 0;
        HRESULT session_hr = IAudioSessionEnumerator_GetSession(session_enumerator, session_index, &session_control);
        if (FAILED(session_hr)) {
            result = (int32_t)session_hr;
            goto done;
        }
        session_hr = IAudioSessionControl_GetState(session_control, &state);
        if (FAILED(session_hr)) {
            IAudioSessionControl_Release(session_control);
            result = (int32_t)session_hr;
            goto done;
        }
        if (state != AudioSessionStateActive) {
            IAudioSessionControl_Release(session_control);
            continue;
        }
        session_hr = IAudioSessionControl_QueryInterface(session_control, &MJA_IID_IAudioSessionControl2, (void **)&session_control2);
        IAudioSessionControl_Release(session_control);
        if (FAILED(session_hr)) {
            result = (int32_t)session_hr;
            goto done;
        }
        session_hr = IAudioSessionControl2_GetProcessId(session_control2, &process_id);
        IAudioSessionControl2_Release(session_control2);
        if (session_hr == AUDCLNT_S_NO_SINGLE_PROCESS) {
            process_id = 0;
        } else if (FAILED(session_hr)) {
            result = (int32_t)session_hr;
            goto done;
        }
        probe->scan[count++] = (uint32_t)process_id;
    }
    qsort(probe->scan, count, sizeof(uint32_t), mja_compare_u32);
    for (sorted_index = 0; sorted_index < count; sorted_index++) {
        if (unique == 0 || probe->scan[unique - 1] != probe->scan[sorted_index]) {
            probe->scan[unique++] = probe->scan[sorted_index];
        }
    }
    probe->scan_count = unique;
done:
    IAudioSessionEnumerator_Release(session_enumerator);
    return result;
}

/* On success probe->external holds the external PIDs of the current active sessions. */
static int32_t mja_probe_poll(mja_output_probe *probe)
{
    int32_t result = mja_probe_list_sessions(probe);
    if (result != 0) return result;
    if (probe->primed && probe->scan_count == probe->session_count &&
        memcmp(probe->scan, probe->sessions, (size_t)probe->scan_count * sizeof(uint32_t)) == 0) {
        return 0;
    }
    probe->primed = 0;
    {
        mja_process_info *processes = NULL;
        uint32_t process_count = 0;
        uint32_t external_count = 0;
        /* The processes are listed after the sessions: see mja_output_filter_external_pids. */
        result = mja_process_snapshot(&processes, &process_count);
        if (result != 0) return result;
        result = mja_output_filter_external_pids(
            probe->scan, probe->scan_count, processes, process_count, (uint32_t)GetCurrentProcessId(),
            probe->external, probe->capacity, &external_count);
        free(processes);
        if (result != 0) return result;
        probe->external_count = external_count;
    }
    memcpy(probe->sessions, probe->scan, (size_t)probe->scan_count * sizeof(uint32_t));
    probe->session_count = probe->scan_count;
    probe->primed = 1;
    return 0;
}

int32_t mja_capture_output_pids(const char *endpoint_id, uint32_t *pids, uint32_t capacity, uint32_t *count)
{
    WCHAR *wide_endpoint = NULL;
    IMMDeviceEnumerator *device_enumerator = NULL;
    IMMDevice *device = NULL;
    mja_output_probe *probe = NULL;
    HRESULT hr;
    int com_initialized = 0;
    int32_t result;
    if (count == NULL || (capacity != 0 && pids == NULL)) return (int32_t)ERROR_INVALID_PARAMETER;
    *count = 0;
    result = mja_utf8_to_wide(endpoint_id, &wide_endpoint);
    if (result != 0) return result;
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        free(wide_endpoint);
        return (int32_t)hr;
    }
    com_initialized = 1;
    hr = CoCreateInstance(&MJA_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &MJA_IID_IMMDeviceEnumerator, (void **)&device_enumerator);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto done;
    }
    hr = IMMDeviceEnumerator_GetDevice(device_enumerator, wide_endpoint, &device);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto done;
    }
    result = mja_probe_create(device, &probe);
    if (result != 0) goto done;
    result = mja_probe_poll(probe);
    if (result != 0) goto done;
    *count = probe->external_count;
    if (probe->external_count > capacity) {
        result = (int32_t)ERROR_INSUFFICIENT_BUFFER;
        goto done;
    }
    if (probe->external_count != 0) memcpy(pids, probe->external, (size_t)probe->external_count * sizeof(uint32_t));
done:
    mja_probe_destroy(probe);
    if (device != NULL) IMMDevice_Release(device);
    if (device_enumerator != NULL) IMMDeviceEnumerator_Release(device_enumerator);
    if (com_initialized) CoUninitialize();
    free(wide_endpoint);
    return result;
}

static uint64_t mja_multiply_divide_u64(uint64_t value, uint64_t multiplier, uint64_t divisor)
{
    uint64_t low_product;
    uint64_t high_product;
    uint64_t low;
    uint64_t high;
    uint64_t remainder = 0;
    uint64_t quotient = 0;
    uint64_t low_part = value & UINT64_C(0xffffffff);
    uint64_t high_part = value >> 32;
    int bit;

    low_product = low_part * multiplier;
    high_product = high_part * multiplier;
    low = low_product + (high_product << 32);
    high = (high_product >> 32) + (low < low_product ? 1u : 0u);
    for (bit = 127; bit >= 0; bit--) {
        uint64_t next_bit = bit >= 64 ? ((high >> (bit - 64)) & 1u) : ((low >> bit) & 1u);
        remainder = (remainder << 1) | next_bit;
        quotient <<= 1;
        if (remainder >= divisor) {
            remainder -= divisor;
            quotient |= 1u;
        }
    }
    return quotient;
}

static int32_t mja_qpc_100ns(LARGE_INTEGER frequency, uint64_t *qpc_100ns)
{
    LARGE_INTEGER counter;
    uint64_t ticks;
    uint64_t frequency_value;
    uint64_t seconds;
    uint64_t remainder;
    uint64_t whole;
    uint64_t fraction;
    if (frequency.QuadPart <= 0 || !QueryPerformanceCounter(&counter)) {
        return frequency.QuadPart <= 0 ? (int32_t)ERROR_INVALID_DATA : mja_last_error_or(ERROR_GEN_FAILURE);
    }
    if (counter.QuadPart < 0) return (int32_t)ERROR_INVALID_DATA;
    ticks = (uint64_t)counter.QuadPart;
    frequency_value = (uint64_t)frequency.QuadPart;
    seconds = ticks / frequency_value;
    remainder = ticks % frequency_value;
    if (seconds > UINT64_MAX / MJA_QPC_UNITS_PER_SECOND) return (int32_t)ERROR_ARITHMETIC_OVERFLOW;
    whole = seconds * MJA_QPC_UNITS_PER_SECOND;
    fraction = mja_multiply_divide_u64(remainder, MJA_QPC_UNITS_PER_SECOND, frequency_value);
    if (whole > UINT64_MAX - fraction) return (int32_t)ERROR_ARITHMETIC_OVERFLOW;
    *qpc_100ns = whole + fraction;
    return 0;
}

typedef struct mja_environment_context {
    mja_capture_environment *environment;
    IMMDeviceEnumerator *enumerator;
    mja_output_probe *probe;
    LARGE_INTEGER frequency;
} mja_environment_context;

static int32_t mja_environment_poll(mja_environment_context *context, uint64_t *qpc_100ns, int32_t *output_state)
{
    mja_capture_environment *environment = context->environment;
    IMMDevice *device = NULL;
    IMMDevice *default_device = NULL;
    LPWSTR default_id = NULL;
    DWORD device_state = 0;
    HRESULT hr;
    int32_t result = mja_qpc_100ns(context->frequency, qpc_100ns);
    *output_state = 0;
    if (result != 0) goto done;
    /* GetDevice per poll keeps the state read live; the enumerator itself is reused. */
    hr = IMMDeviceEnumerator_GetDevice(context->enumerator, environment->endpoint_id, &device);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto done;
    }
    hr = IMMDevice_GetState(device, &device_state);
    if (FAILED(hr)) {
        mja_probe_destroy(context->probe);
        context->probe = NULL;
        result = (int32_t)hr;
        goto done;
    }
    if ((device_state & DEVICE_STATE_ACTIVE) == 0) {
        mja_probe_destroy(context->probe);
        context->probe = NULL;
        result = (int32_t)ERROR_DEVICE_NOT_CONNECTED;
        goto done;
    }
    if (environment->watch_default) {
        EDataFlow flow = environment->loopback ? eRender : eCapture;
        hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(context->enumerator, flow, eConsole, &default_device);
        if (FAILED(hr)) {
            result = (int32_t)hr;
            goto done;
        }
        hr = IMMDevice_GetId(default_device, &default_id);
        if (FAILED(hr)) {
            result = (int32_t)hr;
            goto done;
        }
        {
            int comparison = CompareStringOrdinal(environment->endpoint_id, -1, default_id, -1, TRUE);
            if (comparison == 0) {
                result = mja_last_error_or(ERROR_GEN_FAILURE);
                goto done;
            }
            if (comparison != CSTR_EQUAL) {
                result = MJA_ERROR_DEFAULT_CHANGED;
                goto done;
            }
        }
    }
    if (environment->loopback) {
        if (context->probe == NULL) {
            result = mja_probe_create(device, &context->probe);
            if (result != 0) goto done;
        }
        result = mja_probe_poll(context->probe);
        if (result != 0) goto done;
        *output_state = context->probe->external_count == 0 ? 0 : 1;
    }
done:
    if (default_id != NULL) CoTaskMemFree(default_id);
    if (default_device != NULL) IMMDevice_Release(default_device);
    if (device != NULL) IMMDevice_Release(device);
    return result;
}

/* Publishes one finished poll. The freshness stamp is taken after the poll, so a slow but
 * completing poll is healthy; only a poll that does not complete leaves the stamp stale. */
static int32_t mja_environment_publish_poll(mja_environment_context *context, uint64_t observed_qpc_100ns, int32_t output_state)
{
    uint64_t published_qpc_100ns = 0;
    int32_t result = mja_qpc_100ns(context->frequency, &published_qpc_100ns);
    if (result != 0) return result;
    mja_environment_state_publish(&context->environment->state, observed_qpc_100ns, published_qpc_100ns, output_state, 0);
    return 0;
}

static DWORD WINAPI mja_environment_thread(void *opaque)
{
    mja_capture_environment *environment = (mja_capture_environment *)opaque;
    mja_environment_context context;
    HRESULT hr;
    int com_initialized = 0;
    int32_t result = 0;
    uint64_t qpc_100ns = 0;
    int32_t output_state = -1;

    memset(&context, 0, sizeof(context));
    context.environment = environment;
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto first_poll_complete;
    }
    com_initialized = 1;
    if (!QueryPerformanceFrequency(&context.frequency)) {
        result = mja_last_error_or(ERROR_GEN_FAILURE);
        goto first_poll_complete;
    }
    if (context.frequency.QuadPart <= 0) {
        result = (int32_t)ERROR_INVALID_DATA;
        goto first_poll_complete;
    }
    hr = CoCreateInstance(&MJA_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &MJA_IID_IMMDeviceEnumerator, (void **)&context.enumerator);
    if (FAILED(hr)) {
        result = (int32_t)hr;
        goto first_poll_complete;
    }
    result = mja_environment_poll(&context, &qpc_100ns, &output_state);
    if (result == 0) result = mja_environment_publish_poll(&context, qpc_100ns, output_state);

first_poll_complete:
    if (result != 0) {
        mja_environment_state_publish(&environment->state, qpc_100ns, qpc_100ns, -1, result);
    }
    InterlockedExchange(&environment->startup_error, (LONG)result);
    if (!SetEvent(environment->ready_event)) {
        int32_t event_error = mja_last_error_or(ERROR_GEN_FAILURE);
        if (result == 0) {
            result = event_error;
            InterlockedExchange(&environment->startup_error, (LONG)event_error);
            mja_environment_state_publish(&environment->state, qpc_100ns, qpc_100ns, -1, event_error);
        }
        goto done;
    }
    if (result != 0) goto done;

    for (;;) {
        DWORD wait_result = WaitForSingleObject(environment->stop_event, MJA_ENVIRONMENT_POLL_MS);
        if (wait_result == WAIT_OBJECT_0 || InterlockedCompareExchange(&environment->stop_requested, 0, 0) != 0) {
            break;
        }
        if (wait_result == WAIT_TIMEOUT) {
            result = mja_environment_poll(&context, &qpc_100ns, &output_state);
            if (result == 0) result = mja_environment_publish_poll(&context, qpc_100ns, output_state);
            if (result == 0) continue;
        } else {
            result = mja_last_error_or(ERROR_GEN_FAILURE);
        }
        mja_environment_state_publish(&environment->state, qpc_100ns, qpc_100ns, -1, result);
        break;
    }

done:
    mja_probe_destroy(context.probe);
    if (context.enumerator != NULL) IMMDeviceEnumerator_Release(context.enumerator);
    if (com_initialized) CoUninitialize();
    return 0;
}

static int32_t mja_environment_dispose(mja_capture_environment *environment, int32_t primary_error)
{
    int32_t error = primary_error;
    DWORD wait_result;
    if (environment->thread != NULL) {
        InterlockedExchange(&environment->stop_requested, 1);
        if (environment->stop_event != NULL && !SetEvent(environment->stop_event) && error == 0) {
            error = mja_last_error_or(ERROR_GEN_FAILURE);
        }
        wait_result = WaitForSingleObject(environment->thread, INFINITE);
        if (wait_result != WAIT_OBJECT_0 && error == 0) {
            error = mja_last_error_or(ERROR_GEN_FAILURE);
        }
    }
    {
        int32_t latched_error;
        mja_capture_environment_snapshot(environment, NULL, NULL, NULL, &latched_error);
        if (error == 0 && latched_error != 0) error = latched_error;
    }
    {
        int32_t close_error = mja_close_handle(&environment->stop_event);
        if (error == 0) error = close_error;
        close_error = mja_close_handle(&environment->ready_event);
        if (error == 0) error = close_error;
        close_error = mja_close_handle(&environment->thread);
        if (error == 0) error = close_error;
    }
    free(environment->endpoint_id);
    free(environment);
    return error;
}

int32_t mja_capture_environment_create(const char *endpoint_id, int32_t loopback, int32_t watch_default, mja_capture_environment **out)
{
    mja_capture_environment *environment;
    int32_t error;
    DWORD wait_result;
    if (out == NULL) return (int32_t)ERROR_INVALID_PARAMETER;
    *out = NULL;
    if (endpoint_id == NULL || endpoint_id[0] == '\0' ||
        (loopback != 0 && loopback != 1) || (watch_default != 0 && watch_default != 1)) {
        return (int32_t)ERROR_INVALID_PARAMETER;
    }
    environment = (mja_capture_environment *)calloc(1, sizeof(*environment));
    if (environment == NULL) return (int32_t)ERROR_NOT_ENOUGH_MEMORY;
    mja_environment_state_init(&environment->state);
    error = mja_utf8_to_wide(endpoint_id, &environment->endpoint_id);
    if (error != 0) return mja_environment_dispose(environment, error);
    environment->loopback = loopback;
    environment->watch_default = watch_default;
    environment->ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (environment->ready_event == NULL) return mja_environment_dispose(environment, mja_last_error_or(ERROR_GEN_FAILURE));
    environment->stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (environment->stop_event == NULL) return mja_environment_dispose(environment, mja_last_error_or(ERROR_GEN_FAILURE));
    environment->thread = CreateThread(NULL, 0, mja_environment_thread, environment, 0, NULL);
    if (environment->thread == NULL) return mja_environment_dispose(environment, mja_last_error_or(ERROR_GEN_FAILURE));
    {
        HANDLE startup_handles[2] = {environment->ready_event, environment->thread};
        wait_result = WaitForMultipleObjects(2, startup_handles, FALSE, INFINITE);
    }
    if (wait_result == WAIT_OBJECT_0) {
        error = (int32_t)environment->startup_error;
    } else if (wait_result == WAIT_OBJECT_0 + 1) {
        error = (int32_t)environment->startup_error;
        if (error == 0) error = (int32_t)ERROR_GEN_FAILURE;
    } else {
        error = mja_last_error_or(ERROR_GEN_FAILURE);
    }
    if (error == 0) {
        uint64_t first_qpc;
        uint64_t first_published;
        int32_t first_state;
        int32_t first_error;
        mja_capture_environment_snapshot(environment, &first_qpc, &first_published, &first_state, &first_error);
        if (first_error != 0 || first_state < 0) {
            error = first_error != 0 ? first_error : (int32_t)ERROR_INVALID_DATA;
        }
    }
    if (error != 0) return mja_environment_dispose(environment, error);
    *out = environment;
    return 0;
}

int32_t mja_capture_environment_destroy(mja_capture_environment *environment)
{
    if (environment == NULL) return (int32_t)ERROR_INVALID_PARAMETER;
    return mja_environment_dispose(environment, 0);
}

#endif
