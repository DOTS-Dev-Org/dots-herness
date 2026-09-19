# DOTS Vision native runtime

This is the only native code loaded by `dots.vision-fallback`. It links
`libmtmd` and `libllama` from the pinned llama.cpp commit in `CMakeLists.txt`
and exposes a tiny C ABI for the managed/Swift plugin glue.

Build one artifact per target architecture and copy the resulting
`dots_vision_runtime` library to the plugin package at:

```text
assets/runtime/<platform-library-name>
```

The runtime is CPU-only, loads the GGUF text model plus matching projector in
the caller's process, serializes inference per context, and never opens a
listener or starts a child process.
