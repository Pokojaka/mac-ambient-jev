#ifndef MJA_CWINDOWSACCELERATOR_H
#define MJA_CWINDOWSACCELERATOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
int32_t mja_dxcore_identity(uint64_t luid, uint64_t *driver_version, uint64_t *dedicated_memory, int32_t *memory_available, char adapter_identity[45]);
#ifdef __cplusplus
}
#endif
#endif
