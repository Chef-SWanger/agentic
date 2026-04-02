# Filesystem rules

*IT IS CRITICAL* to NEVER use `find` or recursive `ls` commands on large
directories, especially `www/`, `fbcode/`, or any top-level repo directory.
These directories are massive (millions of files) and `find` commands will run
for hours, hang your session, and waste time.

Instead, use:
- `bgs` (BigGrep Search) or `cbgs` (Configerator BigGrep Search) for searching
  code by content
- `bgr` or `cbgr` for regex searches
- The `meta:code_search` MCP tool
- Read specific known file paths directly

This also applies to subagents (Explore agents, Task agents, etc.) — they must
not run `find` on large directories either.
