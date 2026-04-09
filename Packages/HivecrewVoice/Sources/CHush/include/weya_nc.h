#ifndef WEYA_NC_H
#define WEYA_NC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeyaModel WeyaModel;
typedef struct WeyaSession WeyaSession;

WeyaModel* weya_nc_model_load(void);
WeyaModel* weya_nc_model_load_from_path(const char* path);
void weya_nc_model_free(WeyaModel* model);

WeyaSession* weya_nc_session_create(const WeyaModel* model, size_t input_sr, float atten_lim_db);
void weya_nc_session_free(WeyaSession* session);

size_t weya_nc_get_frame_length(const WeyaSession* session);
size_t weya_nc_get_sample_rate(const WeyaSession* session);
size_t weya_nc_get_input_sample_rate(const WeyaSession* session);

float weya_nc_process_frame(WeyaSession* session, const float* input, float* output);
void weya_nc_reset(WeyaSession* session);

#ifdef __cplusplus
}
#endif

#endif
