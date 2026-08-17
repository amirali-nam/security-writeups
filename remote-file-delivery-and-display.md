# Remote File Delivery & Display on a Lab Host

**Author:** Amirali &nbsp;&nbsp; **Date:** August 2026 &nbsp;&nbsp; **Category:** Network Security / Post-Access Operations

---

## Executive Summary

Once an attacker has credentialed access to a machine, a recurring practical
question is: *how do you move a file onto that machine and make something happen
on it — including on its physical screen — without ever touching its keyboard?*

I worked this end to end in an isolated lab: discover a host purely by scanning
(no prior IP), transfer a file to it over a throwaway HTTP server, and render
that file **on the target's own monitor** from a remote SSH session. The point
was not any single tool — each step uses standard, well-known utilities — but the
**chain**, and specifically the operating-system boundaries that decide *where*
a command's output actually lands.

The real content of this writeup is three debugging problems that each teach a
distinct concept:

| Problem                                  | Root cause                                        | Concept |
| ---------------------------------------- | ------------------------------------------------- | ------- |
| `wget` fails with a TLS error            | `python3 -m http.server` serves plain HTTP, no TLS | transport mismatch |
| `xterm: Can't open display`              | `DISPLAY` unset; `sudo` scrubs the environment    | X11 session + auth |
| X path fails entirely                    | No X server running — target is a text console    | framebuffer vs X |

> ⚠️ **Scope note.** Every action below was performed inside a private lab on
> virtual machines I own, on an isolated internal network. Running these
> techniques against a host you do not own is illegal in most jurisdictions.
> Practice only on hardware you control or on legal platforms (TryHackMe, Hack
> The Box).

---

## Background

Displaying a file remotely sounds trivial until you hit the distinction that
makes it interesting: **running a program on a machine is not the same as making
its output appear on that machine's physical screen.**

When you SSH into a host and run an image viewer, the program executes *on the
target*, but its output is bound to *your* terminal — the SSH channel — not the
target's monitor. To put something on the target's actual display you have to
address whatever is driving that display directly. On Linux that is one of two
things:

- an **X server** (a running graphical session), addressed by the `DISPLAY`
  variable and gated by an `XAUTHORITY` cookie, or
- the **framebuffer** (`/dev/fbN`), the raw kernel drawing surface used when the
  console is text-mode with no graphical session on top.

Knowing which one you are facing — and why the "obvious" command fails on each —
is the whole exercise.

---

## Lab Setup

| Role         | System              | Notes                                             |
| ------------ | ------------------- | ------------------------------------------------- |
| Control node | Linux (VM)          | The machine I drive from, over SSH                |
| Target node  | Linux (VM)          | Has the physical monitor; SSH server enabled      |
| Network      | Internal virtual    | Private `192.168.x.x` range, isolated             |

Both machines run under a local hypervisor. IPs, usernames, and hostnames in the
output below are replaced with placeholders:

- `<control-ip>` — the control node (serves the file)
- `<target-ip>` — the target node (SSH server + physical display)
- `<user>` — the login account on the target

The commands and OS mechanisms are what matter, not the specific addresses.

---

## Methodology

### 1. Find the target by scanning, not by knowing its IP

To mirror a realistic recon step, I never read the target's IP off its own
screen. I enabled SSH on the target:

```
sudo systemctl enable --now ssh     # start now + enable at boot
systemctl status ssh                # confirm active (running)
```

…then, from the control node, discovered it purely with `nmap`:

```
nmap -sn 192.168.1.0/24             # host discovery — which hosts are alive
nmap -sV -p22 <target-ip>           # confirm port 22 open + service version
```

`nmap -sn` does a host-discovery sweep (ARP on a local segment) and returns live
hosts; the follow-up scan confirms port 22 is open and identifies the SSH
service. From there I connected normally:

```
ssh <user>@<target-ip>
```

### 2. Move the file with a throwaway HTTP server

The standard lab pattern for moving a file onto a host you have a shell on: serve
it from the control node and pull it from the target.

On the **control node**, in the directory holding the file:

```
python3 -m http.server 8000         # serves the current dir on 0.0.0.0:8000
```

The `-m` flag matters. `python3 http.server` (without `-m`) makes Python try to
*run a file named* `http.server` and fails with `can't open file`. `-m` tells it
to run the built-in **module**.

On the **target node**, over the SSH session:

```
wget http://<control-ip>:8000/image.gif
```

> This exact pattern — HTTP server on the attacker side, `wget`/`curl` on the
> target — is one of the most common file-transfer techniques in real
> engagements. It is plain HTTP by design: the goal is a fast, dependency-free
> byte move on a trusted segment, not a secure channel.

### 3. Render it on the target's own display

This is the step with all the interesting failure modes — see Findings.

---

## Findings

### Finding 1 — `https://` against a plain HTTP server fails at the TLS layer

The first `wget` attempts failed with:

```
GnuTLS: An unexpected TLS packet was received.
Unable to establish SSL connection.
```

**Analysis.** `python3 -m http.server` speaks **plain HTTP only** — it has no TLS
listener. Requesting `https://` makes `wget` open a TLS handshake, but the server
replies with an ordinary HTTP response, which the client parses as a malformed
TLS record. The fix is simply the correct scheme:

```
wget http://<control-ip>:8000/image.gif      # http, not https
```

A second, unrelated failure in the same phase was a `404`: I had requested
`whoami.gif` when the actual file was `whoami.jpg`. `http.server` matches the
exact path — extension included.

**Takeaway.** Match the transport to what the server actually speaks, and never
assume the extension.

### Finding 2 — `DISPLAY` must point at the graphical session, and `sudo` throws it away

To open a viewer on the target's screen from SSH, I first tried the X11 path and
hit:

```
xterm: Xt error: Can't open display: %s
```

The empty `%s` is the tell: **`DISPLAY` was never set.** An SSH session has no
display of its own, so it must be pointed at the target's local graphical
session (`:0`) explicitly:

```
export DISPLAY=:0
export XAUTHORITY=/home/<user>/.Xauthority   # authorization cookie for :0
```

`DISPLAY` names *which* screen; `XAUTHORITY` grants *permission* to draw on it.
Both are required when the SSH user is not the one that started the graphical
session.

The subtler trap: prefixing the command with `sudo` **scrubbed both variables**
and reproduced the exact same "can't open display" error even after I had set
them. `sudo` starts a clean environment by default. If elevation is genuinely
needed, the variables have to be passed *through* it inline:

```
sudo DISPLAY=:0 XAUTHORITY=/home/<user>/.Xauthority feh --fullscreen image.gif
```

**Takeaway.** `DISPLAY` = which screen, `XAUTHORITY` = permission to use it,
`sudo` = discards both unless you pass them explicitly.

### Finding 3 — No X server: the framebuffer is the correct layer

Even with `DISPLAY` and `XAUTHORITY` set correctly, the X path still failed —
because the target had **no graphical session running at all**. Its monitor was a
plain text console. A quick check settles which world you are in:

```
ls /tmp/.X11-unix/        # X0 present -> X is running (:0); empty -> text console
```

With no X server, there is no display to open — you draw to the **framebuffer**
directly. `fbi` does exactly that:

```
sudo apt install fbi -y
sudo fbi -T 1 -d /dev/fb0 -a --noverbose /home/<user>/image.gif
```

- `-T 1` — target virtual terminal 1
- `-d /dev/fb0` — the framebuffer device
- `-a` — autozoom to fill the screen

This worked: the image rendered full-screen on the target's monitor, driven
entirely from the remote SSH session. The status line `256% 500x211` confirmed
`fbi` had scaled the source up to fill the panel.

**Takeaway.** X and the framebuffer are two different output layers. When there is
no graphical session, `DISPLAY=:0` can never work — the framebuffer is the right
target.

---

## Automation

With the manual chain understood, I wrapped it in a single script run from the
control node. One command transfers the file and displays it on the target:

```bash
#!/bin/bash
# display_remote.sh — from the control node, show an image on the target's monitor
# usage: ./display_remote.sh <image>

# ---- config (fill these in) ----
TARGET_USER="<user>"
TARGET_IP="<target-ip>"
CONTROL_IP="<control-ip>"
HTTP_PORT=9000
FB_DEVICE="/dev/fb0"
TTY_NUM="1"
# --------------------------------

[[ -z "$1" ]] && { echo "usage: $0 <image>"; exit 1; }
FILE="$(realpath "$1")"; [[ -f "$FILE" ]] || { echo "not found: $FILE"; exit 1; }
NAME="$(basename "$FILE")"; DIR="$(dirname "$FILE")"

# serve the file from the control node
pkill -f "http.server $HTTP_PORT" 2>/dev/null; sleep 0.3
( cd "$DIR" && python3 -m http.server "$HTTP_PORT" --quiet ) & HTTP_PID=$!
sleep 0.8

# on the target: pull the file, then render it on the framebuffer
ssh "${TARGET_USER}@${TARGET_IP}" bash <<ENDSSH
  sudo pkill fbi 2>/dev/null; sleep 0.3
  wget -q -O "/tmp/${NAME}" "http://${CONTROL_IP}:${HTTP_PORT}/${NAME}" || exit 1
  sudo fbi -T ${TTY_NUM} -d ${FB_DEVICE} -a --noverbose "/tmp/${NAME}" >/dev/null 2>&1 &
ENDSSH

sleep 2; kill "$HTTP_PID" 2>/dev/null
echo "[+] '${NAME}' displayed on the target monitor."
echo "    clear:  ssh ${TARGET_USER}@${TARGET_IP} 'sudo pkill fbi'"
```

**One-time setup for hands-off operation** (no password prompts):

```
ssh-keygen -t ed25519                                  # if you don't have a key
ssh-copy-id <user>@<target-ip>                         # key-based SSH login
# on the target, allow passwordless sudo for fbi only:
echo '<user> ALL=(ALL) NOPASSWD: /usr/bin/fbi' | sudo tee /etc/sudoers.d/fbi-nopasswd
sudo chmod 440 /etc/sudoers.d/fbi-nopasswd
```

Scoping the `NOPASSWD` rule to a single binary keeps the convenience from
becoming a broad privilege grant.

---

## Why This Matters

Stripped of the tools, the chain is a clean demonstration of three ideas that
generalize well beyond a lab:

1. **You can reach a host without prior knowledge of it** — discovery is a scan,
   not a given.
2. **File transfer is just a reachable server plus a client** — no special
   channel required once you have a shell.
3. **Output is bound to a specific device.** Where a command's result appears is
   an OS decision governed by `DISPLAY`, `XAUTHORITY`, and the X-vs-framebuffer
   split — not by where you typed it.

In offensive terms, rendering to a target's physical display from a remote
session is a vivid way to demonstrate control of a compromised host. But the
transferable skill is the systems knowledge: understanding the boundary between
executing on a machine and controlling what that machine shows.

---

## Defensive Perspective

Every step here assumes the operator already has valid credentials, so the
defense is about **not reaching that point** and **noticing if someone does**:

- **Key-based SSH only** (`PasswordAuthentication no`) removes the easiest path
  to the initial access this whole chain depends on.
- **Egress awareness.** A target pulling files from an unexpected internal HTTP
  server is a signal; unexplained `wget`/`curl` to ad-hoc ports is worth logging.
- **Process monitoring.** Unexpected `fbi`, `feh`, or `xterm` processes spawned
  by a remote session are anomalies on a headless or single-user host.
- **Least-privilege `sudo`.** Scoped `sudoers` rules (as above) limit what a
  compromised account can escalate to.

---

## Cleanup

```
ssh <user>@<target-ip> 'sudo pkill fbi'        # clear the image from the monitor
# remove the transferred file and, if created, the passwordless-sudo rule:
ssh <user>@<target-ip> 'rm -f /tmp/image.gif'
# sudo rm /etc/sudoers.d/fbi-nopasswd          # if you added it and no longer want it
```

---

## Tools Used

- `nmap` — host discovery and service/version detection
- `python3 -m http.server` — throwaway HTTP file server
- `wget` — file retrieval on the target
- `fbi` — framebuffer image viewer (no X required)
- `feh` — X11 image viewer (for hosts with a graphical session)
- `ssh`, `ssh-copy-id`, `sudoers` — remote execution and passwordless operation

---

*This document is a personal technical write-up created for educational and
portfolio purposes. All testing was performed on systems I own and control.*
