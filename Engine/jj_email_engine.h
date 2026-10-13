#ifndef JJ_EMAIL_ENGINE_H
#define JJ_EMAIL_ENGINE_H
void *jj_engine_open(const char *directory);
char *jj_engine_call(void *handle, const char *request);
char *jj_engine_progress(void *handle);
void jj_engine_begin_sync(void *handle);
void jj_engine_cancel(void *handle);
void jj_engine_cancel_search(void *handle, unsigned long long search_id);
void jj_engine_free_string(char *value);
void jj_engine_close(void *handle);
#endif
