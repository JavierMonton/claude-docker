# claude-docker

Run **Claude Code** inside a disposable Docker container — so it can work without being able to
touch your host system or read your credentials. By default Claude runs normally (with its usual
approval prompts); you can opt into `--dangerously-skip-permissions` (fully autonomous, zero
approval prompts) by passing that flag yourself.

Nothing is installed on your machine. It's a single Docker image you build once, launched by a
long `docker run` command that you can wrap in a one-line shell **alias** called as you prefer, e.g.: `claude-docker`.

---

## Quickstart

### 1. Build the image (once)

```sh
docker build -t claude-docker .
```

### 2. Add the alias to your shell

Add this to `~/.zshrc` (or `~/.bashrc`), then restart your shell or `source` it:

```sh
alias claude-docker='docker run --rm -it \
  -v "$PWD":/workspace -w /workspace \
  -v claude-docker-config:/home/node/.claude \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  claude-docker'
```

Optionally, also add a second alias that always runs in YOLO mode by appending
`--dangerously-skip-permissions`. It shares the same config volume, so you only log in once. 
This shouldn't be a risk as long as you only run it on repositories you trust, but be careful:

```sh
alias claude-yolo='docker run --rm -it \
  -v "$PWD":/workspace -w /workspace \
  -v claude-docker-config:/home/node/.claude \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  claude-docker --dangerously-skip-permissions'
```

Now `claude-docker` starts Claude with its normal approval prompts, and `claude-yolo` starts it
fully autonomous.

### 3. Use it

```sh
cd ~/my-project
claude-docker
```

This mounts the **current folder** (`.`) into the container and starts Claude. Any
file Claude creates or edits appears immediately in `~/my-project` on your host, owned by you.
Claude cannot see anything outside that folder.

The **first** time you run it, log in inside the container when prompted. The login is saved and
reused on every future run.

### Common commands

| Command | What it does |
| --- | --- |
| `claude-docker` | Start Claude (normal mode, with approval prompts), mounting the current folder. |
| `claude-docker --dangerously-skip-permissions` | Start Claude in YOLO mode (or use the `claude-yolo` alias above). |
| `claude-docker -p "do X and run it"` | One-shot: run a prompt non-interactively, then exit. |
| `claude-docker --model opus` | Pass any normal `claude` flag straight through. |
| `claude-docker bash` | Open a shell in the sandbox instead of Claude (for debugging). |
| `docker volume rm claude-docker-config` | Log out / reset the saved Claude login. |
| `docker build -t claude-docker .` | Rebuild to refresh the system tools in the image. |

---

## How it works

### The single launch command, explained

```sh
docker run --rm -it \
  -v "$PWD":/workspace -w /workspace \          # mount the current folder; work there
  -v claude-docker-config:/home/node/.claude \  # persistent, isolated Claude login
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \   # so written files are owned by you
  claude-docker
```

- `--rm` — the container is thrown away when you exit. Only the mounted folder and the login
  volume survive.
- `-v "$PWD":/workspace` — the **only** part of your filesystem the container can see.
- `-v claude-docker-config:/home/node/.claude` — a Docker *named volume* holding Claude's login and
  settings. It lives in Docker, not in your home directory, so it's separate from any host login.
- `-e HOST_UID/HOST_GID` — the entrypoint remaps the in-container user to your host ids so files in
  the mounted folder come out owned by you, not by `root` or `node`.

### Security model — and its limits

What you're protected from:

- **Filesystem:** Claude only sees the folder you mount. Your home directory, `~/.ssh`, cloud
  credential files, and the rest of the host are invisible — they are never mounted.
- **Privileges:** Claude runs as the non-root `node` user. (The CLI refuses
  `--dangerously-skip-permissions` as root, which is why the container drops privileges.)
- **Credentials:** the Claude login lives in an isolated Docker volume, not your host home.

What this does **not** protect you from:

- **Network egress is open.** This is deliberate, so Claude can install packages (`pip`, `npm`,
  `uv`, `apt`). But it means a malicious or compromised repository could still exfiltrate whatever
  is inside the mounted folder over the network. **Only run this on repositories you would be
  willing to run anyway, and keep an eye on what Claude does.** No sandbox is completely immune.
- **YOLO mode removes the approval prompts.** When you pass `--dangerously-skip-permissions` (e.g.
  via the `claude-yolo` alias), Claude acts without asking. The container still confines it to the
  mounted folder, but it can change those files freely and run any command with open network access.

### Authentication

On first run, `claude` prompts you to log in inside the container. The token and settings are saved
in the `claude-docker-config` named volume and reused automatically afterwards. To log out or switch
accounts, remove the volume: `docker volume rm claude-docker-config`.

### Updating

- **The Claude CLI updates itself** at runtime by default, so you stay on the latest version
  without doing anything.
- **The system tools** (Python, Node, ripgrep, etc.) are baked into the image. Re-run
  `docker build -t claude-docker .` whenever you want to refresh them.

### What's in the image

Base: `node:22-bookworm`. Pre-installed: `git`, `curl`, `wget`, `ripgrep`, `fd-find`, `jq`,
`build-essential`, `python3` + `pip` + `venv` + `pipx`, [`uv`](https://github.com/astral-sh/uv),
`vim`, `nano`, `gnupg`, `openssh-client`, plus Node/npm and the Claude Code CLI. The `node` user
has **passwordless sudo**, so Claude can `sudo apt-get install …` anything else it needs on the
fly (changes vanish when the container exits). For permanent additions, edit the `Dockerfile` and
rebuild.

### Files in this repo

| File | Purpose |
| --- | --- |
| `Dockerfile` | Defines the sandbox image. |
| `docker-entrypoint.sh` | Remaps uid/gid, drops to the non-root user, runs Claude (passing any flags through). |
| `.dockerignore` | Keeps the build context small. |

---

## Policy

Use of AI code assistants at the Wikimedia Foundation is governed by the
[Secure use guidelines](https://office.wikimedia.org/wiki/Product_&_Technology/AI_Code_Assistants/Secure_use_guidelines)
(staff login required). This sandbox is intended to help meet those guidelines by isolating the
assistant from the host system and host credentials, but it does not replace them — review and
follow the guidelines.
