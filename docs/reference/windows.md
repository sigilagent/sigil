# Sigil on Windows

Sigil runs on jac, and jac ships no Windows build yet. So on Windows, Sigil runs on
Linux underneath, through Docker Desktop or WSL2. One installer sets up either one
and gives you a `sigil` command in PowerShell and cmd that forwards to it:

```powershell
irm https://github.com/sigilagent/sigil/releases/latest/download/install.ps1 | iex
```

It needs no Administrator rights. Running it again updates the install, and so does `sigil update`.

## Which pathway you get

| | Docker | WSL2 |
|---|---|---|
| Picked when | Docker Desktop is running | Docker is not running and a WSL distro exists |
| Force it with | `$env:SIGIL_MODE = "docker"` | `$env:SIGIL_MODE = "wsl"` |
| What runs | the `sigil` container from `ghcr.io/sigilagent/sigil` | the regular Linux install (`install.sh`) inside your distro |
| Your files | your user folder, mounted at `/host` | every drive, under `/mnt/c`, `/mnt/d`, ... |
| Model-written code | stays inside the container | runs as you in the distro, as on Linux |
| Start at login | the container restarts with Docker Desktop (turn on "Start Docker Desktop when you sign in") | a scheduled task named `Sigil`, offered by the installer |

If neither is ready, the installer tells you how to get one:

- **WSL2.** In an Administrator PowerShell, run `wsl --install -d Ubuntu`, restart, and finish Ubuntu's first-run setup.
- **Docker.** Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and start it.

## Using it

```powershell
sigil                          # chat with your agent
sigil setup                    # connect a model
sigil compile .\SKILL.md       # paths are translated for you
sigil solve "turn C:\Users\me\report.pdf into a clean CSV"
```

The Observatory is at http://localhost:8199. After Sigil starts it takes a minute or two
to come up, because it rebuilds its web client.

**Paths.** The `sigil` command maps two things onto Sigil's side: the folder you run it
from, and any argument that names a file or folder that exists. That covers relative
paths such as `.\SKILL.md` as well as absolute ones such as `C:\data\a.csv`. A path written
inside a sentence, like the `solve` example above, is passed through unchanged.
- In the Docker pathway the container only sees your user folder (`/host`). Run `sigil`
  from somewhere inside it, or set `$env:SIGIL_WORKSPACE` to another folder before
  installing.
- In WSL, `C:\x` becomes `/mnt/c/x`.

**Models.** Every connection in [connections](connections.md) works, with two exceptions:
- **Ollama.** If it runs on Windows, the Docker pathway already points the container at
  `http://host.docker.internal:11434`. In WSL, Ollama inside the distro just works, and
  one on Windows needs `OLLAMA_HOST` set to its address.
- **Claude Code.** The Claude Code connection drives the `claude` CLI, which would have to
  be installed where Sigil runs: inside the distro for WSL. It is not available in the
  container.

Browser sign-ins (ChatGPT, OpenRouter) open a link that you click on Windows. The
container receives the sign-in on port 1455, which it publishes only on localhost.

**Claude Code using Sigil's skills** ([claude-code](claude-code.md)) works the same as on macOS:

```powershell
claude mcp add sigil -- sigil mcp-serve
```

## Memory

Sigil's scheduler, Observatory and each command are separate jac processes. Together
they can reach about 10 GB at peak. Docker Desktop and WSL2 give their Linux VM half
your RAM plus swap worth a quarter of it, so a 16 GB PC is comfortable. On a smaller one,
raise the VM's share in `%USERPROFILE%\.wslconfig`, then run `wsl --shutdown`:

```ini
[wsl2]
memory=12GB
swap=8GB
```

## Updating and removing

`sigil update` re-runs the installer. In the Docker pathway it replaces the container
and keeps your graph, compiled skills and settings, which live in the `sigil-graph`,
`sigil-skills` and `sigil-state` volumes.

To remove the Docker pathway:

```powershell
docker rm -f sigil
docker volume rm sigil-state sigil-graph sigil-skills   # deletes your agent's graph, skills and settings
Remove-Item -Recurse "$env:LOCALAPPDATA\Sigil"
```

To remove the WSL pathway:

```powershell
Unregister-ScheduledTask Sigil -Confirm:$false
wsl -- rm -rf ~/.sigil ~/.local/bin/sigil
Remove-Item -Recurse "$env:LOCALAPPDATA\Sigil"
```

Both leave the `sigil` folder on your user PATH (`%LOCALAPPDATA%\Sigil\bin`). It is
harmless once empty.

## The image on its own

The Docker pathway is a plain image, so you can run it yourself:

```bash
docker run -d --name sigil --init --restart unless-stopped \
  -p 127.0.0.1:8199:8199 -p 127.0.0.1:1455:1455 \
  -v sigil-state:/home/jac/.sigil -v sigil-graph:/opt/jac/state/pg \
  -v sigil-skills:/opt/sigil/app/src/crystallized \
  -v "$HOME:/host" ghcr.io/sigilagent/sigil:latest
docker exec -it -w /host sigil sigil      # chat
```

Run every command in that one container with `docker exec`. Never start a second
container on the same volumes: two embedded Postgres servers on one data directory
corrupt it. To build the image from a checkout, run `./docker/build.sh`.
