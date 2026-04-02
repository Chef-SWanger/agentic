# Git Source Control

You are working in a Git repository.

## Checking state
- `git status` — see current changes
- `git diff` — see unstaged changes
- `git diff --cached` — see staged changes
- `git log --oneline -10` — see recent commits

## Making changes
- Stage files: `git add <file>`
- Commit: `git commit -m "message"`
- Amend last commit: `git commit --amend`

## Branch management
- Current branch: `git branch --show-current`
- Switch branch: `git checkout <branch>`
- Rebase: `git rebase <base>`

Always check `git status` before and after making changes to verify you are on
the correct branch and your changes are as expected.
