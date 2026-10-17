#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <objidl.h>
#include <io.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mfreadwrite.h>
#include <new>
#include <limits.h>
#include <stdint.h>
#include <string.h>

#include "CWindowsAudio.h"

enum class WorkerCommand : LONG {
    none = 0,
    read = 1,
    stop = 2
};

struct mja_mf_decoder {
    HANDLE worker;
    HANDLE commandEvent;
    HANDLE completionEvent;
    int fd;
    int isADTS;
    WorkerCommand command;
    HRESULT startupResult;
    HRESULT commandResult;
    HRESULT fatalResult;
    UINT32 sampleRate;
    UINT32 channelCount;
    DWORD blockAlignment;
    IMFSourceReader *reader;
    IMFMediaBuffer *currentBuffer;
    BYTE *bufferData;
    DWORD bufferLength;
    DWORD bufferOffset;
    bool bufferLocked;
    bool endOfStream;
    float *readOutput;
    DWORD requestedFrames;
    DWORD producedFrames;
};

namespace {

constexpr DWORD kMaximumSampleBytes = 4u * 1024u * 1024u;
constexpr DWORD kFirstAudioStream = MF_SOURCE_READER_FIRST_AUDIO_STREAM;

static HRESULT win32_error(DWORD error) {
    return HRESULT_FROM_WIN32(error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error);
}

template <typename T>
static void release_com(T **object) {
    if (object && *object) {
        (*object)->Release();
        *object = nullptr;
    }
}

/*
 * IMFByteStreamOnStream is built around IStream. This implementation exposes
 * only read/seek/stat operations and owns a read-only duplicate of the caller's
 * already-open file handle. SetFilePointerEx and ReadFile are serialized because
 * duplicated Windows handles share the underlying file position.
 */
class ReadOnlyFileStream final : public IStream {
public:
    ReadOnlyFileStream(HANDLE file, LONGLONG size)
        : references_(1), file_(file), size_(size), offset_(0), lockInitialized_(false) {}

    HRESULT initialize() {
        if (!InitializeCriticalSectionEx(&lock_, 0, 0)) return win32_error(GetLastError());
        lockInitialized_ = true;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_ISequentialStream)
            || IsEqualIID(iid, IID_IStream)) {
            *object = static_cast<IStream *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&references_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) {
            if (lockInitialized_) DeleteCriticalSection(&lock_);
            if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
            delete this;
            return 0;
        }
        return static_cast<ULONG>(remaining);
    }

    HRESULT STDMETHODCALLTYPE Read(void *destination, ULONG requested, ULONG *actual) override {
        if (actual) *actual = 0;
        if (requested != 0 && !destination) return E_POINTER;
        if (requested == 0) return S_OK;

        EnterCriticalSection(&lock_);
        if (offset_ >= size_) {
            LeaveCriticalSection(&lock_);
            return S_FALSE;
        }
        const LONGLONG available = size_ - offset_;
        const DWORD toRead = available < static_cast<LONGLONG>(requested)
            ? static_cast<DWORD>(available) : requested;
        LARGE_INTEGER position;
        position.QuadPart = offset_;
        if (!SetFilePointerEx(file_, position, nullptr, FILE_BEGIN)) {
            const HRESULT hr = win32_error(GetLastError());
            LeaveCriticalSection(&lock_);
            return hr;
        }

        DWORD count = 0;
        const BOOL ok = ReadFile(file_, destination, toRead, &count, nullptr);
        const DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        if (!ok && error != ERROR_HANDLE_EOF) {
            LeaveCriticalSection(&lock_);
            return win32_error(error);
        }
        offset_ += count;
        if (actual) *actual = count;
        LeaveCriticalSection(&lock_);
        return count == requested ? S_OK : S_FALSE;
    }

    HRESULT STDMETHODCALLTYPE Write(const void *, ULONG, ULONG *actual) override {
        if (actual) *actual = 0;
        return STG_E_ACCESSDENIED;
    }

    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER distance, DWORD origin,
                                    ULARGE_INTEGER *newPosition) override {
        EnterCriticalSection(&lock_);
        LONGLONG base = 0;
        switch (origin) {
        case STREAM_SEEK_SET: base = 0; break;
        case STREAM_SEEK_CUR: base = offset_; break;
        case STREAM_SEEK_END: base = size_; break;
        default:
            LeaveCriticalSection(&lock_);
            return STG_E_INVALIDFUNCTION;
        }

        const LONGLONG delta = distance.QuadPart;
        if ((delta > 0 && base > LLONG_MAX - delta)
            || (delta < 0 && delta < -base)) {
            LeaveCriticalSection(&lock_);
            return STG_E_SEEKERROR;
        }
        const LONGLONG next = base + delta;
        if (next < 0) {
            LeaveCriticalSection(&lock_);
            return STG_E_SEEKERROR;
        }
        offset_ = next;
        if (newPosition) newPosition->QuadPart = static_cast<ULONGLONG>(offset_);
        LeaveCriticalSection(&lock_);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override {
        return STG_E_ACCESSDENIED;
    }

    HRESULT STDMETHODCALLTYPE CopyTo(IStream *, ULARGE_INTEGER,
                                     ULARGE_INTEGER *read, ULARGE_INTEGER *written) override {
        if (read) read->QuadPart = 0;
        if (written) written->QuadPart = 0;
        return E_NOTIMPL;
    }

    HRESULT STDMETHODCALLTYPE Commit(DWORD) override {
        return STG_E_ACCESSDENIED;
    }

    HRESULT STDMETHODCALLTYPE Revert() override { return E_NOTIMPL; }

    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
        return E_NOTIMPL;
    }

    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
        return E_NOTIMPL;
    }

    HRESULT STDMETHODCALLTYPE Stat(STATSTG *stat, DWORD flags) override {
        if (!stat) return E_POINTER;
        if (flags != STATFLAG_DEFAULT && flags != STATFLAG_NONAME) return STG_E_INVALIDFLAG;
        memset(stat, 0, sizeof(*stat));
        stat->type = STGTY_STREAM;
        stat->cbSize.QuadPart = static_cast<ULONGLONG>(size_);
        stat->grfMode = STGM_READ;
        stat->clsid = GUID_NULL;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Clone(IStream **copy) override {
        if (!copy) return E_POINTER;
        *copy = nullptr;
        return E_NOTIMPL;
    }

private:
    volatile LONG references_;
    HANDLE file_;
    LONGLONG size_;
    LONGLONG offset_;
    CRITICAL_SECTION lock_;
    bool lockInitialized_;
};

static HRESULT create_read_only_stream(int fd, IStream **result) {
    if (!result) return E_POINTER;
    *result = nullptr;

    const intptr_t rawHandle = _get_osfhandle(fd);
    if (rawHandle == -1) return E_INVALIDARG;

    HANDLE duplicate = INVALID_HANDLE_VALUE;
    if (!DuplicateHandle(GetCurrentProcess(), reinterpret_cast<HANDLE>(rawHandle),
                         GetCurrentProcess(), &duplicate, GENERIC_READ, FALSE, 0)) {
        return win32_error(GetLastError());
    }

    BY_HANDLE_FILE_INFORMATION information;
    HRESULT hr = S_OK;
    if (GetFileType(duplicate) != FILE_TYPE_DISK) {
        hr = E_INVALIDARG;
    } else if (!GetFileInformationByHandle(duplicate, &information)) {
        hr = win32_error(GetLastError());
    } else if ((information.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
        hr = E_INVALIDARG;
    }

    LARGE_INTEGER size;
    if (SUCCEEDED(hr) && !GetFileSizeEx(duplicate, &size)) hr = win32_error(GetLastError());
    if (SUCCEEDED(hr) && size.QuadPart < 0) hr = E_INVALIDARG;

    if (FAILED(hr)) {
        CloseHandle(duplicate);
        return hr;
    }

    ReadOnlyFileStream *stream = new (std::nothrow) ReadOnlyFileStream(duplicate, size.QuadPart);
    if (!stream) {
        CloseHandle(duplicate);
        return E_OUTOFMEMORY;
    }
    hr = stream->initialize();
    if (FAILED(hr)) {
        stream->Release();
        return hr;
    }
    *result = static_cast<IStream *>(stream);
    return S_OK;
}

static HRESULT configure_source_reader(mja_mf_decoder *decoder) {
    IStream *stream = nullptr;
    IMFByteStream *byteStream = nullptr;
    IMFAttributes *attributes = nullptr;
    IMFMediaType *nativeType = nullptr;
    IMFMediaType *requestedType = nullptr;
    IMFMediaType *currentType = nullptr;
    GUID majorType = GUID_NULL;
    GUID nativeSubtype = GUID_NULL;
    GUID actualMajor = GUID_NULL;
    GUID actualSubtype = GUID_NULL;
    UINT32 actualRate = 0;
    UINT32 actualChannels = 0;
    UINT32 actualBits = 0;
    UINT32 actualAlignment = 0;
    HRESULT hr = create_read_only_stream(decoder->fd, &stream);
    if (FAILED(hr)) goto done;

    hr = MFCreateMFByteStreamOnStream(stream, &byteStream);
    release_com(&stream);
    if (FAILED(hr)) goto done;

    hr = byteStream->QueryInterface(IID_PPV_ARGS(&attributes));
    if (FAILED(hr)) goto done;
    hr = attributes->SetString(MF_BYTESTREAM_CONTENT_TYPE,
                               decoder->isADTS ? L"audio/aac" : L"video/mp4");
    release_com(&attributes);
    if (FAILED(hr)) goto done;

    /* Deliberately resolve only from the borrowed-handle byte stream, never a URL. */
    hr = MFCreateSourceReaderFromByteStream(byteStream, nullptr, &decoder->reader);
    release_com(&byteStream);
    if (FAILED(hr)) goto done;

    hr = decoder->reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (FAILED(hr)) goto done;
    hr = decoder->reader->SetStreamSelection(kFirstAudioStream, TRUE);
    if (FAILED(hr)) goto done;

    hr = decoder->reader->GetNativeMediaType(kFirstAudioStream, 0, &nativeType);
    if (FAILED(hr)) goto done;

    hr = nativeType->GetGUID(MF_MT_MAJOR_TYPE, &majorType);
    if (FAILED(hr)) goto done;
    hr = nativeType->GetGUID(MF_MT_SUBTYPE, &nativeSubtype);
    if (FAILED(hr)) goto done;
    if (!IsEqualGUID(majorType, MFMediaType_Audio)
        || (!IsEqualGUID(nativeSubtype, MFAudioFormat_AAC)
            && !IsEqualGUID(nativeSubtype, MFAudioFormat_ADTS))) {
        hr = MF_E_INVALIDMEDIATYPE;
        goto done;
    }

    hr = nativeType->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &decoder->sampleRate);
    if (FAILED(hr)) goto done;
    hr = nativeType->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &decoder->channelCount);
    if (FAILED(hr)) goto done;
    if (decoder->sampleRate == 0 || decoder->channelCount == 0 || decoder->channelCount > 254) {
        hr = MF_E_INVALIDMEDIATYPE;
        goto done;
    }
    decoder->blockAlignment = decoder->channelCount * 4;

    hr = MFCreateMediaType(&requestedType);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, decoder->sampleRate);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, decoder->channelCount);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
    if (FAILED(hr)) goto done;
    hr = requestedType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, decoder->blockAlignment);
    if (FAILED(hr)) goto done;
    hr = decoder->reader->SetCurrentMediaType(kFirstAudioStream, nullptr, requestedType);
    if (FAILED(hr)) goto done;

    hr = decoder->reader->GetCurrentMediaType(kFirstAudioStream, &currentType);
    if (FAILED(hr)) goto done;
    hr = currentType->GetGUID(MF_MT_MAJOR_TYPE, &actualMajor);
    if (FAILED(hr)) goto done;
    hr = currentType->GetGUID(MF_MT_SUBTYPE, &actualSubtype);
    if (FAILED(hr)) goto done;
    hr = currentType->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &actualRate);
    if (FAILED(hr)) goto done;
    hr = currentType->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &actualChannels);
    if (FAILED(hr)) goto done;
    hr = currentType->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &actualBits);
    if (FAILED(hr)) goto done;
    hr = currentType->GetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, &actualAlignment);
    if (FAILED(hr)) goto done;
    if (!IsEqualGUID(actualMajor, MFMediaType_Audio)
        || !IsEqualGUID(actualSubtype, MFAudioFormat_Float)
        || actualRate != decoder->sampleRate || actualChannels != decoder->channelCount
        || actualBits != 32 || actualAlignment != decoder->blockAlignment) {
        hr = MF_E_INVALIDMEDIATYPE;
    }

done:
    release_com(&currentType);
    release_com(&requestedType);
    release_com(&nativeType);
    release_com(&attributes);
    release_com(&byteStream);
    release_com(&stream);
    return hr;
}

static void release_current_buffer(mja_mf_decoder *decoder) {
    if (decoder->currentBuffer) {
        if (decoder->bufferLocked) decoder->currentBuffer->Unlock();
        decoder->bufferLocked = false;
        decoder->bufferData = nullptr;
        decoder->bufferLength = 0;
        decoder->bufferOffset = 0;
        release_com(&decoder->currentBuffer);
    }
}

static void worker_cleanup(mja_mf_decoder *decoder) {
    release_com(&decoder->reader);
    release_current_buffer(decoder);
}

static HRESULT acquire_next_buffer(mja_mf_decoder *decoder) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    IMFSample *sample = nullptr;
    HRESULT hr = decoder->reader->ReadSample(kFirstAudioStream, 0, nullptr,
                                               &flags, &timestamp, &sample);
    if (FAILED(hr)) {
        release_com(&sample);
        return hr;
    }
    if ((flags & MF_SOURCE_READERF_ERROR) != 0) {
        release_com(&sample);
        return E_FAIL;
    }
    if ((flags & MF_SOURCE_READERF_STREAMTICK) != 0) {
        release_com(&sample);
        return MF_E_INVALIDREQUEST;
    }
    if ((flags & (MF_SOURCE_READERF_NEWSTREAM
                  | MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED
                  | MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) != 0) {
        release_com(&sample);
        return MF_E_INVALIDMEDIATYPE;
    }
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) decoder->endOfStream = true;

    if (!sample) {
        if (decoder->endOfStream) return S_OK;
        return MF_E_INVALIDREQUEST;
    }

    DWORD totalLength = 0;
    hr = sample->GetTotalLength(&totalLength);
    if (FAILED(hr)) {
        release_com(&sample);
        return hr;
    }
    if (totalLength > kMaximumSampleBytes) {
        release_com(&sample);
        return MF_E_BUFFERTOOSMALL;
    }
    if (totalLength % decoder->blockAlignment != 0) {
        release_com(&sample);
        return MF_E_INVALIDMEDIATYPE;
    }
    if (totalLength == 0) {
        release_com(&sample);
        return S_OK;
    }

    hr = sample->ConvertToContiguousBuffer(&decoder->currentBuffer);
    release_com(&sample);
    if (FAILED(hr)) return hr;

    DWORD maximumLength = 0;
    DWORD currentLength = 0;
    BYTE *data = nullptr;
    hr = decoder->currentBuffer->Lock(&data, &maximumLength, &currentLength);
    if (FAILED(hr)) {
        release_current_buffer(decoder);
        return hr;
    }
    decoder->bufferLocked = true;
    if (currentLength > kMaximumSampleBytes || currentLength > maximumLength
        || currentLength != totalLength || currentLength % decoder->blockAlignment != 0
        || (currentLength != 0 && data == nullptr)) {
        release_current_buffer(decoder);
        return MF_E_INVALIDMEDIATYPE;
    }

    decoder->bufferData = data;
    decoder->bufferLength = currentLength;
    decoder->bufferOffset = 0;
    return S_OK;
}

static HRESULT read_frames(mja_mf_decoder *decoder) {
    if (FAILED(decoder->fatalResult)) return decoder->fatalResult;

    DWORD produced = 0;
    while (produced < decoder->requestedFrames) {
        if (!decoder->currentBuffer) {
            if (decoder->endOfStream) break;
            HRESULT hr = acquire_next_buffer(decoder);
            if (FAILED(hr)) {
                decoder->producedFrames = produced;
                return hr;
            }
            if (!decoder->currentBuffer) {
                if (decoder->endOfStream) break;
                continue;
            }
        }

        const DWORD remainingBytes = decoder->bufferLength - decoder->bufferOffset;
        const DWORD remainingFrames = remainingBytes / decoder->blockAlignment;
        if (remainingFrames == 0) {
            release_current_buffer(decoder);
            continue;
        }
        const DWORD framesToCopy = (decoder->requestedFrames - produced < remainingFrames)
            ? decoder->requestedFrames - produced : remainingFrames;
        const DWORD bytesToCopy = framesToCopy * decoder->blockAlignment;
        const size_t outputOffset = static_cast<size_t>(produced) * decoder->blockAlignment;
        memcpy(reinterpret_cast<BYTE *>(decoder->readOutput) + outputOffset,
               decoder->bufferData + decoder->bufferOffset, bytesToCopy);
        decoder->bufferOffset += bytesToCopy;
        produced += framesToCopy;
        if (decoder->bufferOffset == decoder->bufferLength) release_current_buffer(decoder);
    }

    decoder->producedFrames = produced;
    return S_OK;
}

static DWORD WINAPI decoder_worker(void *context) {
    mja_mf_decoder *decoder = static_cast<mja_mf_decoder *>(context);
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        decoder->startupResult = hr;
        SetEvent(decoder->completionEvent);
        return 1;
    }

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) {
        CoUninitialize();
        decoder->startupResult = hr;
        SetEvent(decoder->completionEvent);
        return 1;
    }

    hr = configure_source_reader(decoder);
    if (FAILED(hr)) {
        worker_cleanup(decoder);
        MFShutdown();
        CoUninitialize();
        decoder->startupResult = hr;
        SetEvent(decoder->completionEvent);
        return 1;
    }

    decoder->startupResult = S_OK;
    SetEvent(decoder->completionEvent);

    for (;;) {
        const DWORD wait = WaitForSingleObject(decoder->commandEvent, INFINITE);
        if (wait != WAIT_OBJECT_0) {
            decoder->fatalResult = win32_error(GetLastError());
            decoder->commandResult = decoder->fatalResult;
            decoder->producedFrames = 0;
            break;
        }

        if (decoder->command == WorkerCommand::stop) break;
        if (decoder->command == WorkerCommand::read) {
            decoder->producedFrames = 0;
            decoder->commandResult = read_frames(decoder);
            if (FAILED(decoder->commandResult)) decoder->fatalResult = decoder->commandResult;
        } else {
            decoder->commandResult = E_UNEXPECTED;
            decoder->fatalResult = decoder->commandResult;
            decoder->producedFrames = 0;
        }
        SetEvent(decoder->completionEvent);
    }

    worker_cleanup(decoder);
    MFShutdown();
    CoUninitialize();
    SetEvent(decoder->completionEvent);
    return 0;
}

static void close_decoder_handles(mja_mf_decoder *decoder) {
    if (decoder->worker) CloseHandle(decoder->worker);
    if (decoder->completionEvent) CloseHandle(decoder->completionEvent);
    if (decoder->commandEvent) CloseHandle(decoder->commandEvent);
}

} // namespace

extern "C" int32_t mja_mf_decoder_create(int fd, int isADTS, mja_mf_decoder **out,
                                          uint32_t *rate, uint32_t *channels) {
    if (out) *out = nullptr;
    if (rate) *rate = 0;
    if (channels) *channels = 0;
    if (!out || !rate || !channels) return static_cast<int32_t>(E_POINTER);
    if (fd < 0 || (isADTS != 0 && isADTS != 1) || _get_osfhandle(fd) == -1) {
        return static_cast<int32_t>(E_INVALIDARG);
    }

    mja_mf_decoder *decoder = new (std::nothrow) mja_mf_decoder{};
    if (!decoder) return static_cast<int32_t>(E_OUTOFMEMORY);
    decoder->fd = fd;
    decoder->isADTS = isADTS;
    decoder->command = WorkerCommand::none;
    decoder->startupResult = E_PENDING;
    decoder->commandResult = E_PENDING;
    decoder->fatalResult = S_OK;

    decoder->commandEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!decoder->commandEvent) {
        const HRESULT hr = win32_error(GetLastError());
        close_decoder_handles(decoder);
        delete decoder;
        return static_cast<int32_t>(hr);
    }
    decoder->completionEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!decoder->completionEvent) {
        const HRESULT hr = win32_error(GetLastError());
        close_decoder_handles(decoder);
        delete decoder;
        return static_cast<int32_t>(hr);
    }
    decoder->worker = CreateThread(nullptr, 0, decoder_worker, decoder, 0, nullptr);
    if (!decoder->worker) {
        const HRESULT hr = win32_error(GetLastError());
        close_decoder_handles(decoder);
        delete decoder;
        return static_cast<int32_t>(hr);
    }

    const DWORD wait = WaitForSingleObject(decoder->completionEvent, INFINITE);
    if (wait != WAIT_OBJECT_0) {
        const HRESULT hr = win32_error(GetLastError());
        decoder->command = WorkerCommand::stop;
        SetEvent(decoder->commandEvent);
        WaitForSingleObject(decoder->worker, INFINITE);
        close_decoder_handles(decoder);
        delete decoder;
        return static_cast<int32_t>(hr);
    }
    if (FAILED(decoder->startupResult)) {
        const HRESULT hr = decoder->startupResult;
        WaitForSingleObject(decoder->worker, INFINITE);
        close_decoder_handles(decoder);
        delete decoder;
        return static_cast<int32_t>(hr);
    }

    *rate = decoder->sampleRate;
    *channels = decoder->channelCount;
    *out = decoder;
    return static_cast<int32_t>(S_OK);
}

extern "C" int32_t mja_mf_decoder_read(mja_mf_decoder *decoder, float *output,
                                        uint32_t capacityFrames, uint32_t *framesRead) {
    if (framesRead) *framesRead = 0;
    if (!decoder || !framesRead || (capacityFrames != 0 && !output)) {
        return static_cast<int32_t>(E_POINTER);
    }
    const uint64_t capacityBytes = static_cast<uint64_t>(capacityFrames) * decoder->blockAlignment;
    if (capacityBytes > SIZE_MAX) return static_cast<int32_t>(E_INVALIDARG);
    if (capacityFrames == 0) return static_cast<int32_t>(S_OK);

    decoder->readOutput = output;
    decoder->requestedFrames = capacityFrames;
    decoder->producedFrames = 0;
    decoder->command = WorkerCommand::read;
    if (!SetEvent(decoder->commandEvent)) return static_cast<int32_t>(win32_error(GetLastError()));
    const DWORD wait = WaitForSingleObject(decoder->completionEvent, INFINITE);
    if (wait != WAIT_OBJECT_0) return static_cast<int32_t>(win32_error(GetLastError()));

    *framesRead = decoder->producedFrames;
    return static_cast<int32_t>(decoder->commandResult);
}

extern "C" void mja_mf_decoder_destroy(mja_mf_decoder *decoder) {
    if (!decoder) return;
    decoder->command = WorkerCommand::stop;
    SetEvent(decoder->commandEvent);
    WaitForSingleObject(decoder->worker, INFINITE);
    close_decoder_handles(decoder);
    delete decoder;
}
