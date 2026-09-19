#include <jni.h>
#include <string>

#include "../../../../../native/MobileGitClient.h"

extern "C" JNIEXPORT jboolean JNICALL
Java_com_dots_herness_mobile_NativeGit_availableNative(JNIEnv *, jclass) {
    return herness_git_available() != 0;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_dots_herness_mobile_NativeGit_executeNative(
    JNIEnv *env,
    jclass,
    jstring operation,
    jstring repo_path,
    jstring argument,
    jstring second,
    jstring token,
    jstring author_name,
    jstring author_email) {
    const char *operation_value = env->GetStringUTFChars(operation, nullptr);
    const char *repo_path_value = env->GetStringUTFChars(repo_path, nullptr);
    const char *argument_value = env->GetStringUTFChars(argument, nullptr);
    const char *second_value = env->GetStringUTFChars(second, nullptr);
    const char *token_value = env->GetStringUTFChars(token, nullptr);
    const char *author_name_value = env->GetStringUTFChars(author_name, nullptr);
    const char *author_email_value = env->GetStringUTFChars(author_email, nullptr);
    char output[64 * 1024] = {0};
    const int code = herness_git_execute(
        operation_value,
        repo_path_value,
        argument_value,
        second_value,
        token_value,
        author_name_value,
        author_email_value,
        output,
        sizeof(output));
    env->ReleaseStringUTFChars(operation, operation_value);
    env->ReleaseStringUTFChars(repo_path, repo_path_value);
    env->ReleaseStringUTFChars(argument, argument_value);
    env->ReleaseStringUTFChars(second, second_value);
    env->ReleaseStringUTFChars(token, token_value);
    env->ReleaseStringUTFChars(author_name, author_name_value);
    env->ReleaseStringUTFChars(author_email, author_email_value);
    return env->NewStringUTF((std::to_string(code) + ":" + output).c_str());
}
