# Commit Cloud Workflow

## 1. Setup Aliases & Start the Server

For manual commands, configure aliases for the Commit Cloud server
(**jj-cc-server**) and custom Jujutsu CLI (**jj**). The VFS alias is only needed
for the optional VFS workflow in section 3:

```bash
alias sjjs=/path/to/jj-commit-cloud-poc/target/release/jj-cc-server
alias sjj=/path/to/jj-commit-cloud-poc/target/release/jj
# Optional, for the VFS workflow in section 3 only:
alias sjjvfs=/path/to/jj-vfs-poc/target/release/jjfsd
```

The native-filesystem workflow does not need the VFS binary. Build the server,
custom `jj`, and its local connection daemon:

```bash
cargo build --release -p jj-commit-cloud-server -p cli -p jj-commit-cloud-daemon
```

You can use `scripts/cc-workflow.sh` to start the local SQLite server and
initialize a workspace in native mode:

```bash
scripts/cc-workflow.sh up \
  --workspace /tmp/cc_native_demo \
  --project-id my-project
```

Native mode stores working files directly in the selected workspace folder and
does not mount or require `jjfsd`. The launcher uses SQLite by default and
stores its database, process IDs, and logs under its state directory. Pass
`--store-type spanner --spanner-db <SPANNER_RESOURCE>` to use Spanner. Set
`JJ_CC_SERVER_BIN`, `JJ_CC_JJ_BIN`, or `JJ_CC_DAEMON_BIN` to select binaries
outside the default build paths. `JJ_CC_PROFILE=debug` selects debug paths.

Use `scripts/cc-workflow.sh status` to view the server and
`scripts/cc-workflow.sh down` to stop the managed server. `down` leaves the
SQLite database and workspace files in place. The custom `jj` binary runs
commands as needed; its local connection daemon starts automatically on the
first RPC and remains running after `down`.

Start the Commit Cloud server with the persistent SQLite storage backend *(as of srachaba-3-store-errors)*:

```bash
sjjs --port 8080 --store-type sqlite
```

Or start the server backed by Google Cloud Spanner *(as of srachaba-spanner)*:

```bash
# Spanner works automatically (auto-initializes schema tables)—just provide the Spanner database link:
sjjs --port 8080 --store-type spanner --spanner-db <SPANNER_LINK>
```

## 2. Initialize a Native Filesystem Workspace

Create a folder for the workspace and initialize it against the running server.
The `local` working-copy type means checkout and edits happen in this folder on
the machine's native filesystem. Commits and other Commit Cloud objects still
use the configured remote server.

```bash
mkdir -p /tmp/cc_native_demo && cd /tmp/cc_native_demo
sjj cc init --server http://localhost:8080 \
  --project-id <PROJECT_ID> \
  --working-copy-type local .
```

For example, create and commit files directly in that folder:

```bash
cd /tmp/cc_native_demo
printf 'hello from the native working copy\n' > hello.txt
sjj status
sjj new
sjj commit -m "Add hello.txt"
```

The launcher selects `--working-copy-type local` when it initializes a new
workspace. Working-copy type is chosen at initialization, so use a new folder
when switching an existing Commit Cloud workspace to native mode. For an
existing folder that you have already initialized with `--working-copy-type
local`, pass `--reuse-existing-workspace` to the launcher.

## 3. Optional Sparse Checkout & VFS Integration *(as of srachaba-working-copy)*

![Sparse & VFS Workflow](./sparse_workflow.png)

To use the VFS workflow instead, build `jjfsd` from the sibling VFS project:

```bash
(cd ../jj-vfs-poc && cargo build --release --bin jjfsd)
```

The launcher can clear the working copy and start the mount in one step:

```bash
scripts/cc-workflow.sh up \
  --mode vfs \
  --workspace /tmp/vfs_demo \
  --mount /tmp/vfs_mount \
  --project-id my-project \
  --clear-working-copy
```

For a workspace and server started manually, clear physical files from the
working copy and mount the VFS directly:

```bash
# Clear physical working copy from local disk
sjj sparse set --clear

# Mount the VFS at /tmp/vfs_mount pointing to /tmp/vfs_demo
mkdir -p /tmp/vfs_mount
sjjvfs /tmp/vfs_mount /tmp/vfs_demo

# Browse files at a specific commit ID or workspace via VFS
cat /tmp/vfs_mount/commits/<commit_id>/file.txt
cat /tmp/vfs_mount/workspaces/default/file.txt

# Selectively materialize paths on local disk to edit
sjj sparse set --add file.txt
```

## 4. Import an Existing Git Repository *(as of srachaba-git-hash-import)*

Import an existing local Git repository into a Commit Cloud project and repository:

```bash
sjj cc import-git \
  --git-dir /path/to/local/git/repo \
  --project-id <PROJECT_ID> \
  --repo-id <REPO_ID> \
  --server http://localhost:8080
```
