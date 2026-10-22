#ifndef MJA_WINDOWS_CAPTURE_ENVIRONMENT_H
#define MJA_WINDOWS_CAPTURE_ENVIRONMENT_H

#include <stdint.h>

typedef struct mja_capture_environment mja_capture_environment;

int32_t mja_capture_environment_create(const char *endpoint_id, int32_t loopback, int32_t watch_default, mja_capture_environment **out);
/* observed is the QPC when the poll started (the watermark of the reported state);
 * published is the QPC when the poll finished (freshness is measured from it). */
void mja_capture_environment_snapshot(mja_capture_environment *environment, uint64_t *observed_qpc_100ns, uint64_t *published_qpc_100ns, int32_t *output_state, int32_t *error);
int32_t mja_capture_environment_destroy(mja_capture_environment *environment);

#endif
