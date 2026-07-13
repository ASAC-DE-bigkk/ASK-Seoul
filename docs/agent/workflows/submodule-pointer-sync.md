# Submodule pointer synchronization

`ASK-Seoul` records `dags`, `dbt`, and future child repositories as Git
submodule gitlinks. A child merge does not update the parent gitlink, so a root
checkout can otherwise continue to run an older child commit.

## Standard flow

1. Merge the child repository PR into its agreed integration branch.
2. Start from a clean `ASK-Seoul` branch based on the root integration branch.
3. Run the helper with the same child branch:

   ```bash
   ./scripts/update-submodule-pointers.sh --branch dev
   ```

   Use `--dry-run` first to inspect every child update without changing the
   checkout or index:

   ```bash
   ./scripts/update-submodule-pointers.sh --branch dev --dry-run
   ```

4. Review the staged diff. It must contain only the configured submodule paths:

   ```bash
   git diff --cached --submodule=log --name-status
   ./scripts/agent/validate-submodule-pointers.sh
   ```

5. Commit and open a root PR that links the child PRs. The root PR updates
   gitlinks only; child source files are never copied into the root repository.

## Safety contract

- The helper requires an explicit branch; it never assumes `main` or `prod`.
- A non-dry run stops when the root or any submodule worktree is dirty.
- The helper fetches each configured submodule from its own `origin` remote.
- Only the gitlink paths from `.gitmodules` are staged automatically.
- The helper does not merge, push, trigger Airflow, run dbt, or write to R2.
- If a child repository is not merged yet, wait for its merge commit before
  updating the root pointer.

## Scope

The procedure applies to every submodule declared in `.gitmodules`; it is not
specific to a domain or to `dags`/`dbt`.
