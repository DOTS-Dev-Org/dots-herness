# Workspace scan policy

HerNess uses one local file policy for the project map, file index, Tree-sitter code graph,
background memory study and automatic workspace search on macOS, Windows and Linux.

## Defaults

Inside a Git working tree, HerNess considers tracked files and untracked files that Git does
not ignore. Tracked files matched by .gitignore are excluded too. Outside a Git working
tree, the scanner applies .gitignore files while walking the folder.

By default, HerNess skips its fixed build, dependency and runtime directories. It always
skips symbolic links, .env* files, common credential and secret names, private-key and
database file formats, plus .git, .mem, .ssh and .gnupg paths. The app-level private-path
exclusions cannot be overridden by project files.

## Project exclusions

Create .hernessignore in the workspace root to keep project paths out of automatic scans.
It supports comments, *, ?, **, directory suffixes and ordered ! exceptions:

```gitignore
# Generated API clients
Generated/

# Keep the schema used to build those clients in the map and graph
!Generated/api-schema.json

# Local experiment files
experiments/*.swift
```

An exclusion applies to the map, graph, file index and background study alike.

## Selectively include Git-ignored files

Create .hernessinclude in the workspace root and add one exact, workspace-relative file
path per line. This can opt a generated source file into every automatic scan even when
.gitignore or .hernessignore excludes it:

```text
Generated/APIClient.swift
```

Entries must name existing files; wildcards, directories, absolute paths, paths outside the
workspace, symlinks and the app-level private exclusions are ignored. An exact include can
opt into a file inside a default-skipped build or dependency directory. Keep this list narrow.

## First prompt

On macOS, a new project now gets a quick file outline and a path-based file index in the
first prompt. The detailed map and Tree-sitter graph start building in the background; until
the graph is ready, HerNess uses the file index. Windows and Linux use the same scan policy
and already start a missing graph from an ordinary code request.
