#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CWindowsHTTP.h"

struct msj_http_response {
    HINTERNET session;
    HINTERNET connect;
    HINTERNET request;
};

static uint32_t fail(const char **failed_call, const char *call) {
    DWORD code = GetLastError();
    *failed_call = call;
    return code == 0 ? ERROR_INTERNAL_ERROR : (uint32_t)code;
}

uint32_t msj_http_open(const wchar_t *url, int64_t range_start,
                       msj_http_response **out, const char **failed_call) {
    *out = NULL;
    *failed_call = NULL;
    uint32_t code = 0;
    wchar_t *host = NULL;
    wchar_t *path = NULL;
    wchar_t *range = NULL;
    msj_http_response *r = (msj_http_response *)calloc(1, sizeof(*r));
    if (!r) {
        *failed_call = "calloc";
        return ERROR_OUTOFMEMORY;
    }

    URL_COMPONENTS parts;
    memset(&parts, 0, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = (DWORD)-1;
    parts.dwUrlPathLength = (DWORD)-1;
    parts.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(url, 0, 0, &parts)) {
        code = fail(failed_call, "WinHttpCrackUrl");
        goto cleanup;
    }
    if (parts.nScheme != INTERNET_SCHEME_HTTPS) {
        SetLastError(ERROR_INVALID_PARAMETER);
        code = fail(failed_call, "https required");
        goto cleanup;
    }
    host = (wchar_t *)calloc(parts.dwHostNameLength + 1, sizeof(wchar_t));
    path = (wchar_t *)calloc(parts.dwUrlPathLength + parts.dwExtraInfoLength + 1, sizeof(wchar_t));
    if (!host || !path) {
        *failed_call = "calloc";
        code = ERROR_OUTOFMEMORY;
        goto cleanup;
    }
    memcpy(host, parts.lpszHostName, parts.dwHostNameLength * sizeof(wchar_t));
    memcpy(path, parts.lpszUrlPath, parts.dwUrlPathLength * sizeof(wchar_t));
    memcpy(path + parts.dwUrlPathLength, parts.lpszExtraInfo, parts.dwExtraInfoLength * sizeof(wchar_t));

    r->session = WinHttpOpen(L"MacAmbientJev", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!r->session) { code = fail(failed_call, "WinHttpOpen"); goto cleanup; }
    if (!WinHttpSetTimeouts(r->session, 0, 30000, 30000, 60000)) {
        code = fail(failed_call, "WinHttpSetTimeouts");
        goto cleanup;
    }
    r->connect = WinHttpConnect(r->session, host, parts.nPort, 0);
    if (!r->connect) { code = fail(failed_call, "WinHttpConnect"); goto cleanup; }
    r->request = WinHttpOpenRequest(r->connect, L"GET", path, NULL, WINHTTP_NO_REFERER,
                                    WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!r->request) { code = fail(failed_call, "WinHttpOpenRequest"); goto cleanup; }

    if (range_start >= 0) {
        range = (wchar_t *)calloc(64, sizeof(wchar_t));
        if (!range) { *failed_call = "calloc"; code = ERROR_OUTOFMEMORY; goto cleanup; }
        swprintf(range, 64, L"Range: bytes=%lld-", (long long)range_start);
        if (!WinHttpAddRequestHeaders(r->request, range, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD)) {
            code = fail(failed_call, "WinHttpAddRequestHeaders");
            goto cleanup;
        }
    }
    if (!WinHttpSendRequest(r->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        code = fail(failed_call, "WinHttpSendRequest");
        goto cleanup;
    }
    if (!WinHttpReceiveResponse(r->request, NULL)) {
        code = fail(failed_call, "WinHttpReceiveResponse");
        goto cleanup;
    }
    *out = r;
    r = NULL;

cleanup:
    free(host);
    free(path);
    free(range);
    msj_http_close(r);
    return code;
}

uint32_t msj_http_status(msj_http_response *r, uint32_t *status, const char **failed_call) {
    DWORD value = 0;
    DWORD size = sizeof(value);
    if (!WinHttpQueryHeaders(r->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &value, &size, WINHTTP_NO_HEADER_INDEX)) {
        return fail(failed_call, "WinHttpQueryHeaders(status)");
    }
    *status = value;
    return 0;
}

uint32_t msj_http_content_range(msj_http_response *r, wchar_t *buf, uint32_t capacity,
                                int *present, const char **failed_call) {
    DWORD size = capacity * (DWORD)sizeof(wchar_t);
    *present = 0;
    if (!WinHttpQueryHeaders(r->request, WINHTTP_QUERY_CONTENT_RANGE, WINHTTP_HEADER_NAME_BY_INDEX,
                             buf, &size, WINHTTP_NO_HEADER_INDEX)) {
        DWORD code = GetLastError();
        if (code == ERROR_WINHTTP_HEADER_NOT_FOUND) return 0;
        *failed_call = "WinHttpQueryHeaders(content-range)";
        return (uint32_t)code;
    }
    *present = 1;
    return 0;
}

uint32_t msj_http_read(msj_http_response *r, void *buf, uint32_t capacity, uint32_t *read,
                       const char **failed_call) {
    DWORD got = 0;
    if (!WinHttpReadData(r->request, buf, capacity, &got)) {
        return fail(failed_call, "WinHttpReadData");
    }
    *read = got;
    return 0;
}

void msj_http_close(msj_http_response *r) {
    if (!r) return;
    if (r->request) WinHttpCloseHandle(r->request);
    if (r->connect) WinHttpCloseHandle(r->connect);
    if (r->session) WinHttpCloseHandle(r->session);
    free(r);
}
