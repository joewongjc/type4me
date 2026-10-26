#include "Type4MeJiebaBridge.h"

#include <exception>
#include <memory>
#include <string>
#include <vector>

#include "cppjieba/DictTrie.hpp"
#include "cppjieba/HMMModel.hpp"
#include "cppjieba/MixSegment.hpp"
#include "cppjieba/QuerySegment.hpp"

struct T4MJiebaHandle {
    cppjieba::DictTrie dictionary;
    cppjieba::HMMModel hmm;
    cppjieba::MixSegment accurate;
    cppjieba::QuerySegment search;

    T4MJiebaHandle(
        const std::string &dictionary_path,
        const std::string &hmm_model_path,
        const std::string &user_dictionary_path
    ) : dictionary(dictionary_path, user_dictionary_path),
        hmm(hmm_model_path),
        accurate(&dictionary, &hmm),
        search(&dictionary, &hmm) {}
};

T4MJiebaHandle *t4m_jieba_create(
    const char *dictionary_path,
    const char *hmm_model_path,
    const char *user_dictionary_path
) {
    if (!dictionary_path || !hmm_model_path || !user_dictionary_path) {
        return nullptr;
    }
    try {
        return new T4MJiebaHandle(
            dictionary_path,
            hmm_model_path,
            user_dictionary_path
        );
    } catch (const std::exception &) {
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

void t4m_jieba_destroy(T4MJiebaHandle *handle) {
    delete handle;
}

void t4m_jieba_purge_global_cache(void) {
    cppjieba::DictTrie::PurgeDictCache();
}

bool t4m_jieba_cut(
    T4MJiebaHandle *handle,
    const char *utf8_text,
    bool search_mode,
    T4MJiebaTokenCallback callback,
    void *context
) {
    if (!handle || !utf8_text || !callback) {
        return false;
    }
    try {
        std::vector<cppjieba::Word> words;
        if (search_mode) {
            handle->search.Cut(utf8_text, words, true);
        } else {
            handle->accurate.Cut(utf8_text, words, true);
        }
        for (const auto &word : words) {
            callback(word.word.data(), word.word.size(), word.offset, context);
        }
        return true;
    } catch (const std::exception &) {
        return false;
    } catch (...) {
        return false;
    }
}

bool t4m_jieba_insert_user_word(
    T4MJiebaHandle *handle,
    const char *utf8_word,
    int frequency
) {
    if (!handle || !utf8_word || utf8_word[0] == '\0') {
        return false;
    }
    try {
        return handle->dictionary.InsertUserWord(utf8_word, frequency);
    } catch (const std::exception &) {
        return false;
    } catch (...) {
        return false;
    }
}
