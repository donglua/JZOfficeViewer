#ifndef JZ_OFFICE_H
#define JZ_OFFICE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char* data;
    char* error;
} JZStringResult;

typedef struct {
    uint8_t* data;
    size_t len;
    char* error;
} JZBytesResult;

JZStringResult jz_office_parse_path(const char* path_utf8);
JZStringResult jz_office_parse_first_viewport(const char* path_utf8);
JZStringResult jz_office_metadata_path(const char* path_utf8);
JZStringResult jz_office_prewarm_search_index(const char* path_utf8);
JZStringResult jz_office_search_path(const char* path_utf8, const char* query_utf8);
JZBytesResult jz_office_read_part(const char* path_utf8, const char* part_utf8);
void jz_office_evict_cache(const char* path_utf8);
void jz_office_clear_cache(void);
void jz_office_free_string(char* ptr);
void jz_office_free_bytes(uint8_t* ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* JZ_OFFICE_H */
