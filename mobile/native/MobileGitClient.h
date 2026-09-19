#ifndef HERNESS_MOBILE_GIT_CLIENT_H
#define HERNESS_MOBILE_GIT_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    HERNESS_GIT_OK = 0,
    HERNESS_GIT_ERROR = 1,
    HERNESS_GIT_UNAVAILABLE = 2,
};

/*
 * Execute one libgit2 operation.
 *
 * operation: clone, fetch, checkout, create_branch, status, diff, commit, push
 * repo_path: local repository path; clone uses the destination path
 * argument:   URL, branch, or commit message, depending on operation
 * second:     branch/remote, depending on operation
 * token:      in-memory credential only; never written to Git config
 * author_*:   commit identity
 * output:     caller-owned result/error buffer
 */
int herness_git_execute(const char *operation,
                        const char *repo_path,
                        const char *argument,
                        const char *second,
                        const char *token,
                        const char *author_name,
                        const char *author_email,
                        char *output,
                        size_t output_capacity);

int herness_git_available(void);

#ifdef __cplusplus
}
#endif

#endif
