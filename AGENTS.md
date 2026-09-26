# OpenCode project instructions

- All code comments, commit messages, pull request text, and agent-authored repository documentation must be in English unless the task explicitly requires another language.
- GitHub Actions runs are headless. Never request interactive approval or wait for user input.
- Keep all temporary files and test fixtures inside the repository worktree. Do not use `/tmp`, `/var/tmp`, the runner home directory, or any other path outside the worktree.
- If temporary storage is needed, create it under `.opencode-tmp/` in the repository, remove it before committing, and never include it in a commit.
- If a command is blocked because it would access an external directory, rewrite the command to operate entirely inside the repository and continue; do not retry the blocked external path.
- Before finishing a task, run the relevant tests or validation, inspect `git status` and `git diff`, then commit and push the intended changes as required by the invoking task.
