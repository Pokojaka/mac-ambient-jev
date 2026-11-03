#ifndef MAC_AMBIENT_WINDOWS_HTTP_H
#define MAC_AMBIENT_WINDOWS_HTTP_H
#include <stdint.h>
#include <wchar.h>

/* A blocking HTTPS GET, one response per handle. Every function returns 0 on success or the
 * Win32 error code of the failing call, and sets *failed_call to a static string naming it. */
typedef struct msj_http_response msj_http_response;

/* GET `url` (https only). range_start < 0 sends no Range header; otherwise it sends
 * "Range: bytes=<range_start>-". On success *out owns the session, connect and request handles. */
uint32_t msj_http_open(const wchar_t *url, int64_t range_start,
                       msj_http_response **out, const char **failed_call);
uint32_t msj_http_status(msj_http_response *r, uint32_t *status, const char **failed_call);
/* Writes the Content-Range value into buf (capacity in wchar_t, including NUL).
 * *present = 0 and returns 0 when the header is absent. */
uint32_t msj_http_content_range(msj_http_response *r, wchar_t *buf, uint32_t capacity,
                                int *present, const char **failed_call);
/* Reads up to `capacity` bytes. *read == 0 means end of body. */
uint32_t msj_http_read(msj_http_response *r, void *buf, uint32_t capacity, uint32_t *read,
                       const char **failed_call);
/* Closes request, connect and session in that order. NULL is a no-op. */
void msj_http_close(msj_http_response *r);
#endif
