#ifndef MAC_AMBIENT_WINDOWS_SESSION_H
#define MAC_AMBIENT_WINDOWS_SESSION_H
#include <stdint.h>
#include <wchar.h>

typedef void *MSJHandle;
uint32_t msj_open_root(const wchar_t *path, int create, int writable, MSJHandle *result);
/* kind: -1 either, 0 regular file, 1 directory. Never follows a reparse point. */
uint32_t msj_open_at(MSJHandle parent, const wchar_t *name, int kind, int writable,
                     int create, int exclusive, int deletable, MSJHandle *result);
void msj_close(MSJHandle handle);
int msj_descriptor(MSJHandle handle, int writable);
uint32_t msj_kind(MSJHandle handle, int *directory);
uint32_t msj_size(MSJHandle handle, int64_t *size);
uint32_t msj_flush(MSJHandle handle);
uint32_t msj_lock(MSJHandle handle);
uint32_t msj_remove(MSJHandle handle);
uint32_t msj_rename(MSJHandle handle, MSJHandle destination, const wchar_t *name);
typedef void (*MSJEntryCallback)(const wchar_t *name, void *context);
uint32_t msj_list(MSJHandle handle, MSJEntryCallback callback, void *context);
uint32_t msj_local_app_data(wchar_t **path);
void msj_free_path(wchar_t *path);
#endif
