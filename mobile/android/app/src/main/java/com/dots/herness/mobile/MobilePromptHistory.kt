package com.dots.herness.mobile

/** Initial policy is pinned; host updates are captured only on a new user turn. */
internal class MobilePromptHistory(initialPolicy: String? = null) {
    var policy: String? = initialPolicy
        private set

    fun capture(prompt: String, currentPolicy: String, context: String): String {
        if (policy == null) policy = currentPolicy
        return buildList {
            if (currentPolicy != policy) add("<runtime_context>\n$currentPolicy\n</runtime_context>")
            if (context.isNotEmpty()) add(context)
            add(prompt)
        }.joinToString("\n\n")
    }
}
