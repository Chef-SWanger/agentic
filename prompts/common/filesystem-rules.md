# Filesystem rules

*IT IS CRITICAL* to NEVER use `find` or recursive `ls` commands on large
directories. Large repositories can contain millions of files and `find` commands
will run for hours, hang your session, and waste time.

Instead, use:
- Targeted `grep` or `rg` (ripgrep) for searching code by content
- `git ls-files` to list tracked files
- Read specific known file paths directly
- IDE-style tools (Glob, Grep) if available

This also applies to subagents — they must not run `find` on large directories.
