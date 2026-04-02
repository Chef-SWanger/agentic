# Sapling Source Control

You are working in a Sapling (sl) repository.

## Checking state
- `sl status` — see current changes
- `sl diff` — see uncommitted changes
- `sl log -l 10` — see recent commits

## Making changes
- Commit: `sl commit -m "message"`
- Amend current commit: `sl amend`
- Create a new commit on top: `sl commit -m "message"`

## Stack management
- Go to a commit: `sl goto <hash>`
- Rebase: `sl rebase -s <source> -d <dest>`
- Pull latest: `sl pull`
- Sync to remote: `sl goto remote/master`

## Working with diffs
- Submit for review: `sl pr submit`
- Check stack: `sl log -G`

Always check `sl status` and `sl log -l 5` before and after making changes to
verify you are on the correct commit and your changes are as expected.
