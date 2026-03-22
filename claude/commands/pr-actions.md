# PR Actions

You are helping the user act on their open GitHub PRs.

## Step 1 — Load current PR state

Run the pr-reminder script to get a fresh snapshot:

```sh
/Users/justin.maher/src/quick_tools/pr-reminder/pr_reminder.sh run
```

Then read the updated note:

```
/Users/justin.maher/Library/Mobile Documents/iCloud~md~obsidian/Documents/Appfolio/Appfolio/todo/open-prs.md
```

## Step 2 — Present actions for approval

Parse every PR and its suggested action from the note. Group them into:

**Can be automated:**
- 🚧 Mark ready for review → `gh pr ready <url>`
- ✅ Ready to merge → `gh pr merge <url> --squash`
- 🔄 Rebase — behind base branch → check out the branch, rebase onto base, force-push

**Needs manual work (flag only, do not attempt to automate):**
- 💬 Address requested changes — requires code changes
- ❌ Fix CI — requires investigation
- 👀 Awaiting review — nothing to do yet

Show the user a numbered list of the automatable items with a one-line description of what will happen. Ask: "Which of these should I action? (numbers, 'all', or 'none')"

## Step 3 — Execute approved actions via subagent

For each approved action, spawn a subagent to execute it. Pass the subagent the PR URL, the action type, and any context it needs.

### Mark ready for review
```sh
gh pr ready <url>
```

### Merge
Confirm the merge strategy before running. Default to `--squash` unless the repo convention differs.
```sh
gh pr merge <url> --squash
```

### Rebase
The subagent must:
1. Determine the repo from the PR URL (e.g. `appfolio/front-end-platform`)
2. Find the local clone path by checking `~/src/<repo-name>` or asking the user if not found
3. Check out the PR branch: `gh pr checkout <url>`
4. Identify the base branch from `gh pr view <url> --json baseRefName`
5. Rebase: `git rebase origin/<base>`
6. Force-push: `git push --force-with-lease`
7. Return to the previous branch

If there are conflicts during rebase, stop, report them, and do not force-push.

## Step 4 — Report results

After all subagents complete, summarize what was done and what still needs manual attention.
