#include "MobileGitClient.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#if defined(HERNESS_HAS_LIBGIT2) && HERNESS_HAS_LIBGIT2
#  if defined(__has_include)
#    if __has_include(<git2.h>)
#      include <git2.h>
#      define HERNESS_MOBILE_HAS_LIBGIT2 1
#    endif
#  endif
#endif

#ifndef HERNESS_MOBILE_HAS_LIBGIT2
#define HERNESS_MOBILE_HAS_LIBGIT2 0
#endif

static void clear_output(char *output, size_t capacity) {
    if (output && capacity > 0) output[0] = '\0';
}

static void write_output(char *output, size_t capacity, const char *format, ...) {
    if (!output || capacity == 0) return;
    va_list args;
    va_start(args, format);
    vsnprintf(output, capacity, format, args);
    va_end(args);
    output[capacity - 1] = '\0';
}

#if HERNESS_MOBILE_HAS_LIBGIT2

typedef struct {
    const char *token;
} herness_git_credentials;

typedef struct {
    char *output;
    size_t capacity;
} herness_git_buffer;

static const char *last_error(void) {
    const git_error *error = git_error_last();
    return error && error->message ? error->message : "libgit2 operation failed.";
}

static int fail(char *output, size_t capacity, int code) {
    write_output(output, capacity, "%s", last_error());
    return code;
}

static int credentials_cb(git_cred **out,
                          const char *url,
                          const char *username_from_url,
                          unsigned int allowed_types,
                          void *payload) {
    (void)url;
    herness_git_credentials *credentials = (herness_git_credentials *)payload;
    if (!credentials || !credentials->token || !credentials->token[0]) return GIT_PASSTHROUGH;
    if (!(allowed_types & GIT_CREDTYPE_USERPASS_PLAINTEXT)) return GIT_PASSTHROUGH;
    return git_cred_userpass_plaintext_new(
        out,
        username_from_url && username_from_url[0] ? username_from_url : "x-access-token",
        credentials->token);
}

static void configure_fetch_callbacks(git_fetch_options *options, herness_git_credentials *credentials) {
    options->callbacks = (git_remote_callbacks)GIT_REMOTE_CALLBACKS_INIT;
    options->callbacks.credentials = credentials_cb;
    options->callbacks.payload = credentials;
}

static int configure_push_callbacks(git_push_options *options, herness_git_credentials *credentials) {
    options->remote_callbacks = (git_remote_callbacks)GIT_REMOTE_CALLBACKS_INIT;
    options->remote_callbacks.credentials = credentials_cb;
    options->remote_callbacks.payload = credentials;
    return 0;
}

static int open_repository(git_repository **repository, const char *path, char *output, size_t capacity) {
    int code = git_repository_open(repository, path);
    return code == 0 ? HERNESS_GIT_OK : fail(output, capacity, HERNESS_GIT_ERROR);
}

static int do_clone(const char *url,
                    const char *path,
                    const char *branch,
                    const char *token,
                    char *output,
                    size_t capacity) {
    git_clone_options options = GIT_CLONE_OPTIONS_INIT;
    herness_git_credentials credentials = { token };
    configure_fetch_callbacks(&options.fetch_opts, &credentials);
    if (branch && branch[0]) options.checkout_branch = branch;
    git_repository *repository = NULL;
    int code = git_clone(&repository, url, path, &options);
    if (repository) git_repository_free(repository);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "cloned");
    return HERNESS_GIT_OK;
}

static int do_fetch(git_repository *repository, const char *token, char *output, size_t capacity) {
    git_remote *remote = NULL;
    int code = git_remote_lookup(&remote, repository, "origin");
    if (code == 0) {
        git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
        herness_git_credentials credentials = { token };
        configure_fetch_callbacks(&options, &credentials);
        code = git_remote_fetch(remote, NULL, &options, NULL);
    }
    if (remote) git_remote_free(remote);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "fetched");
    return HERNESS_GIT_OK;
}

static int do_checkout(git_repository *repository, const char *branch, char *output, size_t capacity) {
    if (!branch || !branch[0]) {
        write_output(output, capacity, "A branch is required.");
        return HERNESS_GIT_ERROR;
    }
    git_object *object = NULL;
    int code = git_revparse_single(&object, repository, branch);
    if (code == 0) {
        git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
        options.checkout_strategy = GIT_CHECKOUT_SAFE;
        code = git_checkout_tree(repository, object, &options);
    }
    if (code == 0) {
        char ref_name[1024];
        if (strncmp(branch, "refs/", 5) == 0) {
            snprintf(ref_name, sizeof(ref_name), "%s", branch);
        } else {
            snprintf(ref_name, sizeof(ref_name), "refs/heads/%s", branch);
        }
        code = git_repository_set_head(repository, ref_name);
    }
    if (object) git_object_free(object);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "checked out %s", branch);
    return HERNESS_GIT_OK;
}

static int do_create_branch(git_repository *repository, const char *branch, char *output, size_t capacity) {
    if (!branch || !branch[0]) {
        write_output(output, capacity, "A branch is required.");
        return HERNESS_GIT_ERROR;
    }
    git_oid head_oid;
    int code = git_reference_name_to_id(&head_oid, repository, "HEAD");
    git_commit *head = NULL;
    git_reference *reference = NULL;
    if (code == 0) code = git_commit_lookup(&head, repository, &head_oid);
    if (code == 0) code = git_branch_create(&reference, repository, branch, head, 0);
    if (reference) git_reference_free(reference);
    if (head) git_commit_free(head);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "created branch %s", branch);
    return HERNESS_GIT_OK;
}

static int status_cb(const char *path, unsigned int status_flags, void *payload) {
    herness_git_buffer *buffer = (herness_git_buffer *)payload;
    if (!buffer || !path) return 0;
    size_t used = buffer->output ? strlen(buffer->output) : 0;
    if (used + 32 >= buffer->capacity) return 1;
    int written = snprintf(buffer->output + used, buffer->capacity - used, "%08x %s\n", status_flags, path);
    return written < 0 || (size_t)written >= buffer->capacity - used;
}

static int do_status(git_repository *repository, char *output, size_t capacity) {
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX;
    herness_git_buffer buffer = { output, capacity };
    int code = git_status_foreach_ext(repository, &options, status_cb, &buffer);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    if (!output || !output[0]) write_output(output, capacity, "clean");
    return HERNESS_GIT_OK;
}

static int diff_cb(const git_diff_delta *delta,
                   const git_diff_hunk *hunk,
                   const git_diff_line *line,
                   void *payload) {
    (void)delta;
    (void)hunk;
    herness_git_buffer *buffer = (herness_git_buffer *)payload;
    if (!buffer || !buffer->output || !line) return 0;
    size_t used = strlen(buffer->output);
    if (used + line->content_len + 1 >= buffer->capacity) return 1;
    memcpy(buffer->output + used, line->content, line->content_len);
    buffer->output[used + line->content_len] = '\0';
    return 0;
}

static int do_diff(git_repository *repository, char *output, size_t capacity) {
    git_diff *diff = NULL;
    git_diff_options options = GIT_DIFF_OPTIONS_INIT;
    int code = git_diff_index_to_workdir(&diff, repository, NULL, &options);
    if (code == 0) {
        herness_git_buffer buffer = { output, capacity };
        code = git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, diff_cb, &buffer);
    }
    if (diff) git_diff_free(diff);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    if (!output || !output[0]) write_output(output, capacity, "clean");
    return HERNESS_GIT_OK;
}

static int do_commit(git_repository *repository,
                     const char *message,
                     const char *author_name,
                     const char *author_email,
                     char *output,
                     size_t capacity) {
    if (!message || !message[0] || !author_name || !author_name[0] || !author_email || !author_email[0]) {
        write_output(output, capacity, "Commit message and author identity are required.");
        return HERNESS_GIT_ERROR;
    }
    git_index *index = NULL;
    git_tree *tree = NULL;
    git_commit *parent = NULL;
    git_signature *signature = NULL;
    int code = git_repository_index(&index, repository);
    if (code == 0) code = git_index_add_all(index, NULL, GIT_INDEX_ADD_DEFAULT, NULL, NULL);
    if (code == 0) code = git_index_write(index);
    git_oid tree_oid;
    if (code == 0) code = git_index_write_tree(&tree_oid, index);
    if (code == 0) code = git_tree_lookup(&tree, repository, &tree_oid);
    int has_parent = git_repository_head_unborn(repository) == 0;
    git_oid parent_oid;
    if (code == 0 && has_parent) code = git_reference_name_to_id(&parent_oid, repository, "HEAD");
    if (code == 0 && has_parent) code = git_commit_lookup(&parent, repository, &parent_oid);
    if (code == 0) code = git_signature_now(&signature, author_name, author_email);
    if (code == 0) {
        git_oid commit_oid;
        const git_commit *parents[1] = { parent };
        code = git_commit_create(
            &commit_oid,
            repository,
            "HEAD",
            signature,
            signature,
            NULL,
            message,
            tree,
            has_parent ? 1 : 0,
            parents);
    }
    if (signature) git_signature_free(signature);
    if (parent) git_commit_free(parent);
    if (tree) git_tree_free(tree);
    if (index) git_index_free(index);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "committed");
    return HERNESS_GIT_OK;
}

static int do_push(git_repository *repository,
                   const char *remote_name,
                   const char *branch,
                   const char *token,
                   char *output,
                   size_t capacity) {
    const char *remote_value = remote_name && remote_name[0] ? remote_name : "origin";
    const char *branch_value = branch && branch[0] ? branch : "HEAD";
    git_reference *head_reference = NULL;
    git_remote *remote = NULL;
    int code = git_remote_lookup(&remote, repository, remote_value);
    git_push_options options = GIT_PUSH_OPTIONS_INIT;
    herness_git_credentials credentials = { token };
    if (code == 0) configure_push_callbacks(&options, &credentials);
    char refspec[2048];
    if (code == 0) {
        if (strcmp(branch_value, "HEAD") == 0) {
            code = git_repository_head(&head_reference, repository);
            if (code == 0) branch_value = git_reference_shorthand(head_reference);
        }
        snprintf(refspec, sizeof(refspec), "refs/heads/%s:refs/heads/%s", branch_value, branch_value);
        char *spec_values[1] = { refspec };
        git_strarray specs = { spec_values, 1 };
        code = git_remote_push(remote, &specs, &options);
    }
    if (head_reference) git_reference_free(head_reference);
    if (remote) git_remote_free(remote);
    if (code != 0) return fail(output, capacity, HERNESS_GIT_ERROR);
    write_output(output, capacity, "pushed");
    return HERNESS_GIT_OK;
}

#endif

int herness_git_available(void) {
    return HERNESS_MOBILE_HAS_LIBGIT2;
}

int herness_git_execute(const char *operation,
                        const char *repo_path,
                        const char *argument,
                        const char *second,
                        const char *token,
                        const char *author_name,
                        const char *author_email,
                        char *output,
                        size_t output_capacity) {
    clear_output(output, output_capacity);
#if !HERNESS_MOBILE_HAS_LIBGIT2
    (void)operation;
    (void)repo_path;
    (void)argument;
    (void)second;
    (void)token;
    (void)author_name;
    (void)author_email;
    write_output(output, output_capacity, "libgit2_not_linked");
    return HERNESS_GIT_UNAVAILABLE;
#else
    if (!operation || !operation[0]) {
        write_output(output, output_capacity, "A Git operation is required.");
        return HERNESS_GIT_ERROR;
    }
    git_libgit2_init();
    if (strcmp(operation, "clone") == 0) return do_clone(argument, repo_path, second, token, output, output_capacity);

    git_repository *repository = NULL;
    int result = open_repository(&repository, repo_path, output, output_capacity);
    if (result != HERNESS_GIT_OK) return result;
    if (strcmp(operation, "fetch") == 0) result = do_fetch(repository, token, output, output_capacity);
    else if (strcmp(operation, "checkout") == 0) result = do_checkout(repository, argument, output, output_capacity);
    else if (strcmp(operation, "create_branch") == 0) result = do_create_branch(repository, argument, output, output_capacity);
    else if (strcmp(operation, "status") == 0) result = do_status(repository, output, output_capacity);
    else if (strcmp(operation, "diff") == 0) result = do_diff(repository, output, output_capacity);
    else if (strcmp(operation, "commit") == 0) result = do_commit(repository, argument, author_name, author_email, output, output_capacity);
    else if (strcmp(operation, "push") == 0) result = do_push(repository, argument, second, token, output, output_capacity);
    else {
        write_output(output, output_capacity, "Unsupported Git operation: %s", operation);
        result = HERNESS_GIT_ERROR;
    }
    git_repository_free(repository);
    return result;
#endif
}
