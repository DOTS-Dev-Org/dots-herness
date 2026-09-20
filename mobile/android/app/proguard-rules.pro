# The native C ABI resolves this object by its generated JNI class name.
-keep class com.dots.herness.mobile.NativeGit { *; }

# WorkManager instantiates this worker from its persisted class name.
-keep class com.dots.herness.mobile.LoopWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
    *;
}

# Rhino references the optional JavaBeans API for JVM environments; Android does
# not ship that API and this conversion path is not used by the mobile runtime.
-dontwarn java.beans.**
