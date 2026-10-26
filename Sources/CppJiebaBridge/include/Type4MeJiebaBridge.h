#ifndef TYPE4ME_JIEBA_BRIDGE_H
#define TYPE4ME_JIEBA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct T4MJiebaHandle T4MJiebaHandle;

typedef void (*T4MJiebaTokenCallback)(
    const char *word,
    size_t word_length,
    size_t byte_offset,
    void *context
);

T4MJiebaHandle *t4m_jieba_create(
    const char *dictionary_path,
    const char *hmm_model_path,
    const char *user_dictionary_path
);

void t4m_jieba_destroy(T4MJiebaHandle *handle);

void t4m_jieba_purge_global_cache(void);

bool t4m_jieba_cut(
    T4MJiebaHandle *handle,
    const char *utf8_text,
    bool search_mode,
    T4MJiebaTokenCallback callback,
    void *context
);

bool t4m_jieba_insert_user_word(
    T4MJiebaHandle *handle,
    const char *utf8_word,
    int frequency
);

#ifdef __cplusplus
}
#endif

#endif
