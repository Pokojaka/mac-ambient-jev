#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <winternl.h>
#include <shlobj.h>
#include <io.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include "CWindowsSession.h"

/* Native relative opens keep the same boundary as POSIX openat, even if a
 * directory is moved after opening. CreateFileW alone cannot do relative opens. */
typedef NTSTATUS (NTAPI *CreateAtFn)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
    PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
typedef NTSTATUS (NTAPI *SetInfoFn)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, FILE_INFORMATION_CLASS);
typedef ULONG (WINAPI *DosErrorFn)(NTSTATUS);

static DWORD dos_error(NTSTATUS status) {
    DosErrorFn convert = (DosErrorFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlNtStatusToDosError");
    return convert ? convert(status) : ERROR_PROC_NOT_FOUND;
}

uint32_t msj_kind(MSJHandle handle, int *directory) {
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(handle, &info)) return GetLastError();
    if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) || GetFileType(handle) != FILE_TYPE_DISK)
        return ERROR_CANT_ACCESS_FILE;
    *directory = !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
    return ERROR_SUCCESS;
}

uint32_t msj_open_root(const wchar_t *path, int create, int writable, MSJHandle *result) {
    /* CreateFileW must not truncate a long boundary to Win32's MAX_PATH. */
    DWORD needed = GetFullPathNameW(path, 0, NULL, NULL);
    if (!needed) return GetLastError();
    wchar_t *absolute = calloc(needed, sizeof(wchar_t));
    wchar_t *extended = calloc((size_t)needed + 8, sizeof(wchar_t));
    if (!absolute || !extended) { free(absolute); free(extended); return ERROR_NOT_ENOUGH_MEMORY; }
    DWORD length = GetFullPathNameW(path, needed, absolute, NULL);
    if (!length || length >= needed) {
        DWORD error = length ? ERROR_FILENAME_EXCED_RANGE : GetLastError();
        free(absolute); free(extended); return error;
    }
    if (!wcsncmp(absolute, L"\\\\?\\", 4)) wmemcpy(extended, absolute, length + 1);
    else if (!wcsncmp(absolute, L"\\\\", 2)) {
        wmemcpy(extended, L"\\\\?\\UNC\\", 8); wmemcpy(extended + 8, absolute + 2, length - 1);
    } else { wmemcpy(extended, L"\\\\?\\", 4); wmemcpy(extended + 4, absolute, length + 1); }
    free(absolute);
    if (create && !CreateDirectoryW(extended, NULL)) {
        DWORD error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) { free(extended); return error; }
    }
    HANDLE handle = CreateFileW(extended, GENERIC_READ | (writable ? GENERIC_WRITE : 0),
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
    DWORD open_error = handle == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
    free(extended);
    if (open_error) return open_error;
    int directory = 0;
    DWORD error = msj_kind(handle, &directory);
    if (!error && !directory) error = ERROR_DIRECTORY;
    if (error) { CloseHandle(handle); return error; }
    *result = handle;
    return ERROR_SUCCESS;
}

uint32_t msj_open_at(MSJHandle parent, const wchar_t *name, int kind, int writable,
                     int create, int exclusive, int deletable, MSJHandle *result) {
    size_t length = wcslen(name);
    if (!length || length > 32766 || wcspbrk(name, L"\\/:")) return ERROR_INVALID_NAME;
    CreateAtFn open_at = (CreateAtFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile");
    if (!open_at) return ERROR_PROC_NOT_FOUND;
    UNICODE_STRING unicode = {(USHORT)(length * sizeof(wchar_t)), (USHORT)(length * sizeof(wchar_t)), (PWSTR)name};
    OBJECT_ATTRIBUTES attributes = {sizeof(attributes), parent, &unicode, OBJ_CASE_INSENSITIVE, NULL, NULL};
    IO_STATUS_BLOCK io;
    HANDLE handle;
    ACCESS_MASK access = GENERIC_READ | SYNCHRONIZE;
    if (writable) access |= GENERIC_WRITE;
    if (deletable) access |= DELETE;
    ULONG options = 0x00200000 /* FILE_OPEN_REPARSE_POINT */
                  | 0x00000020 /* FILE_SYNCHRONOUS_IO_NONALERT */
                  | 0x00000002 /* FILE_WRITE_THROUGH */;
    if (kind == 1) options |= 0x00000001; /* FILE_DIRECTORY_FILE */
    if (kind == 0) options |= 0x00000040; /* FILE_NON_DIRECTORY_FILE */
    NTSTATUS status = open_at(&handle, access, &attributes, &io, NULL, FILE_ATTRIBUTE_NORMAL,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        exclusive ? 2 /* FILE_CREATE */ : create ? 3 /* FILE_OPEN_IF */ : 1 /* FILE_OPEN */,
        options, NULL, 0);
    if (status < 0) return dos_error(status);
    int actual;
    DWORD error = msj_kind(handle, &actual);
    if (!error && kind >= 0 && kind != actual) error = ERROR_INVALID_NAME;
    if (error) { CloseHandle(handle); return error; }
    *result = handle;
    return ERROR_SUCCESS;
}

void msj_close(MSJHandle handle) { CloseHandle(handle); }

int msj_descriptor(MSJHandle handle, int writable) {
    return _open_osfhandle((intptr_t)handle, _O_BINARY | (writable ? _O_RDWR : _O_RDONLY));
}

uint32_t msj_size(MSJHandle handle, int64_t *size) {
    LARGE_INTEGER length;
    if (!GetFileSizeEx(handle, &length)) return GetLastError();
    *size = length.QuadPart;
    return ERROR_SUCCESS;
}

uint32_t msj_flush(MSJHandle handle) {
    return FlushFileBuffers(handle) ? ERROR_SUCCESS : GetLastError();
}

uint32_t msj_lock(MSJHandle handle) {
    OVERLAPPED position = {0};
    return LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK, 0, MAXDWORD, MAXDWORD, &position)
        ? ERROR_SUCCESS : GetLastError();
}

uint32_t msj_remove(MSJHandle handle) {
    FILE_DISPOSITION_INFO info = {TRUE};
    return SetFileInformationByHandle(handle, FileDispositionInfo, &info, sizeof(info))
        ? ERROR_SUCCESS : GetLastError();
}

uint32_t msj_rename(MSJHandle handle, MSJHandle destination, const wchar_t *name) {
    SetInfoFn set_info = (SetInfoFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetInformationFile");
    if (!set_info) return ERROR_PROC_NOT_FOUND;
    /* FILE_RENAME_INFORMATION_EX. POSIX semantics replace a destination that
     * another process holds open with FILE_SHARE_DELETE; file systems without
     * them fail the call instead of falling back to the non-POSIX replace. */
    struct RenameInfo { ULONG flags; HANDLE root; ULONG length; WCHAR name[1]; };
    size_t bytes = wcslen(name) * sizeof(wchar_t);
    size_t size = offsetof(struct RenameInfo, name) + bytes;
    struct RenameInfo *info = calloc(1, size);
    if (!info) return ERROR_NOT_ENOUGH_MEMORY;
    info->flags = 0x00000001 /* FILE_RENAME_REPLACE_IF_EXISTS */
                | 0x00000002 /* FILE_RENAME_POSIX_SEMANTICS */;
    info->root = destination;
    info->length = (ULONG)bytes;
    memcpy(info->name, name, bytes);
    IO_STATUS_BLOCK io;
    NTSTATUS status = set_info(handle, &io, info, (ULONG)size, (FILE_INFORMATION_CLASS)65 /* FileRenameInformationEx */);
    free(info);
    return status < 0 ? dos_error(status) : ERROR_SUCCESS;
}

uint32_t msj_list(MSJHandle handle, MSJEntryCallback callback, void *context) {
    const DWORD capacity = 64 * 1024;
    BYTE *buffer = malloc(capacity);
    if (!buffer) return ERROR_NOT_ENOUGH_MEMORY;
    BOOL first = TRUE;
    DWORD error = ERROR_SUCCESS;
    while (GetFileInformationByHandleEx(handle,
        first ? FileFullDirectoryRestartInfo : FileFullDirectoryInfo, buffer, capacity)) {
        first = FALSE;
        FILE_FULL_DIR_INFO *entry = (FILE_FULL_DIR_INFO *)buffer;
        for (;;) {
            size_t count = entry->FileNameLength / sizeof(wchar_t);
            wchar_t *name = calloc(count + 1, sizeof(wchar_t));
            if (!name) { error = ERROR_NOT_ENOUGH_MEMORY; goto done; }
            memcpy(name, entry->FileName, entry->FileNameLength);
            if (wcscmp(name, L".") && wcscmp(name, L"..")) callback(name, context);
            free(name);
            if (!entry->NextEntryOffset) break;
            entry = (FILE_FULL_DIR_INFO *)((BYTE *)entry + entry->NextEntryOffset);
        }
    }
    error = GetLastError();
    if (error == ERROR_NO_MORE_FILES) error = ERROR_SUCCESS;
done:
    free(buffer);
    return error;
}

uint32_t msj_local_app_data(wchar_t **path) {
    HRESULT result = SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DEFAULT, NULL, path);
    return SUCCEEDED(result) ? ERROR_SUCCESS : (uint32_t)result;
}

void msj_free_path(wchar_t *path) { CoTaskMemFree(path); }
