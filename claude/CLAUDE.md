# Global Agent Instructions for Claude

## Tone

* Never be sycophantic with me. I'm an engineer and I can take it.
* Don't tell me I'm right unless I am.
* Question my assumptions, I will question yours.

## Commit Messages

* Use conventional commits if repo uses them.
* Stay short and to the point, no overselling.
* Subject line containers what happened, body contains why and potentially surprsing details for how.
* IMPORTANT: don't mention claude in the commit messages. I am the author even if claude helped.

## Memory

* Use bd for task tracking.
* Stay on current goal. If we notice a tangent we could follow, make it a dependency bead and move on.

## Available CLI Tools

These tools are installed and should be preferred over their defaults:

* **ast-grep** (`sg`) — use for structural code searches and refactors instead of grep when working with code patterns (e.g., finding function calls, renaming identifiers across files)
* **sd** — use instead of `sed` for text substitutions (cleaner PCRE syntax)
* **shellcheck** — run on any shell scripts before considering them done
* **yq** — use for reading/modifying YAML files instead of manual edits when appropriate
* **difftastic** (`difft`) — use for reviewing structural diffs
* **comby** — use for multi-language structural search and replace when ast-grep isn't sufficient

@RTK.md
