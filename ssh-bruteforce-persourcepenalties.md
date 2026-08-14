# SSH Brute-Force Attack & Defense Analysis

**Author:** Amirali **Date:** August 2026 **Category:** Network Security / SSH Hardening

---

## Executive Summary

I set up an isolated virtualization lab to answer a single question end to end:
*if an attacker finds an open SSH port on my network, can they get in — and what
actually stops them?* Rather than stopping at "run a brute-force tool, get a
shell," I worked the problem from **both sides** — the attacker optimizing for
speed, and the defender optimizing for security without punishing normal users.

The key finding was not the attack itself, but a modern, **built-in OpenSSH
defense (`PerSourcePenalties`)** that was already active by default on the target
and shaped every outcome. Password authentication was ultimately breakable, but
only once that defense was removed — and even then the real lesson was in the
numbers, not the crack.

| Attack configuration        | Server defense           | Outcome                        |
| --------------------------- | ------------------------ | ------------------------------ |
| Hydra `-t 16` (default)     | `PerSourcePenalties` on  | Self-throttled, attack aborted |
| Hydra `-t 1` (slow)         | `PerSourcePenalties` on  | Runs at ~18 tries/min — impractical |
| Hydra `-t 16`               | `PerSourcePenalties` off | ~220 tries/min, password recovered |

> ⚠️ Note: Every action below was performed inside a private lab on virtual
> machines I own, on an isolated internal network. Brute-forcing SSH against a
> host you do not own — even "just to test" — is a crime in most jurisdictions.
> Only run this on hardware you control or on legal platforms (TryHackMe, Hack
> The Box).

---

## Background

SSH brute-force is one of the most common attacks against internet- and
network-facing hosts. Any machine with an open SSH port (default 22) can be
found by a simple scan, and once found, an attacker can request a connection and
begin guessing credentials without any prior access to the system.

SSH does have a per-connection limit on authentication attempts
(`MaxAuthTries`, default 6), which looks like a defense but is easily bypassed by
automated tooling that simply opens a new connection for each batch of guesses.
The interesting question is therefore not "can you brute-force SSH" (you can) but
"what makes it *not worth it*" — which turns out to be a rate-limiting /
economics problem, not an absolute wall.

---

## Lab Setup

| Role     | System           | Notes                                   |
| -------- | ---------------- | --------------------------------------- |
| Target   | Kali Linux (VM)  | OpenSSH server, default configuration   |
| Attacker | Fedora (VM)      | Hydra as the brute-force tool           |
| Network  | Internal virtual | Private `192.168.x.x` range, isolated   |

Both machines run under QEMU/KVM. A throwaway user was created on the target
purely for the test:

```
sudo useradd -m testuser
sudo passwd testuser          # weak password, present in rockyou.txt
```

IPs, usernames, and hostnames in the output below are redacted or replaced with
placeholders — the commands and mechanisms are what matter.

---

## Methodology

### 1. Understanding the service

Before attacking anything, I worked through the SSH service on the target:
enabling/disabling it, observing live sessions, and learning to identify and
terminate a specific connection.

```
sudo systemctl enable --now ssh     # start + enable at boot
systemctl status ssh                # verify active (running)
```

Two behaviours stood out:

- **Disabling a service does not kill existing sessions.** `systemctl disable
  --now ssh` stops *new* connections, but sessions already established stay alive
  until they close.
- **Killing a shell is not the same as killing a connection.** `pkill -t pts/N`
  only killed the upper shell layers of a session, dropping me back to the login
  shell instead of disconnecting. To cut the connection at the root I targeted
  the `sshd` process itself:

```
ps aux | grep sshd          # find "sshd: <user>@pts/N"
kill -9 <PID>               # SIGKILL — cannot be caught or ignored
```

### 2. The attack — Hydra

From the attacker VM, using the `f3`-equivalent standard tool for this job,
`hydra`:

```
hydra -l testuser -P /path/to/rockyou.txt ssh://<target-ip>
```

- `-l testuser` → single username (`-L` for a username list)
- `-P rockyou.txt` → password wordlist
- `ssh://<target-ip>` → protocol + target
- `-t N` → number of parallel connections (tasks)

### 3. Inspecting the defense

When the attack behaved unexpectedly, I read the target's effective SSH
configuration to find what was interfering:

```
sudo sshd -T | grep -i penal
```

> ⚠️ Note: For the controlled test in Finding 3, `PerSourcePenalties` was
> temporarily disabled on the target. It was re-enabled during cleanup — this is
> a real protection and should not be left off.

---

## Findings

### Finding 1 — `MaxAuthTries` is a speed bump, not a wall

Brute-force defeats the per-connection attempt limit by opening a **new
connection** for each batch of guesses. In the target logs, every attempt shows a
different session ID and source port:

```
sshd-session[...]: Failed password for testuser ... port 47176 ssh2
sshd-session[...]: Failed password for testuser ... port 47132 ssh2
sshd-session[...]: Failed password for testuser ... port 47208 ssh2
```

**Analysis:** Different ports = different connections. `MaxAuthTries` (default 6)
caps guesses *within* one connection but does nothing to stop thousands of fresh
connections. Two defensive layers are also visible in the logs: `sshd-session`
(SSH accepting the connection) and `unix_chkpwd` / `pam_unix` (PAM checking the
password against `/etc/shadow`).

**Impact:** On its own, `MaxAuthTries` provides negligible protection against an
automated attacker.

---

### Finding 2 — A "failed" attack that wasn't real security

Running Hydra at its default 16 parallel tasks produced what looked like a win
for the defender:

```
[ERROR] all children were disabled due too many connection errors
0 of 1 target completed, 0 valid password found
```

But the target logs told the real story:

```
sshd[...]: drop connection #1 from [<attacker-ip>] penalty: failed authentication
```

Reading the effective config revealed a built-in penalty system:

```
persourcepenalties crash:90 authfail:5 noauth:1 invaliduser:5
                   grace-exceeded:10 refuseconnection:10
                   max:600 min:15 max-sources4:65536 ... overflow:permissive
```

| Parameter                        | Meaning                                        |
| -------------------------------- | ---------------------------------------------- |
| `authfail:5`                     | +5 seconds of penalty per failed authentication|
| `min:15`                         | minimum block time once triggered (15s)        |
| `max:600`                        | maximum block time (10 min) for a persistent source |
| `noauth:1` / `refuseconnection:10` | penalties for connections that never authenticate |

**Analysis:** Modern OpenSSH ships with `PerSourcePenalties` enabled by default —
effectively a lightweight fail2ban inside the daemon. Hydra's rapid failures
pushed the attacker IP past the penalty threshold; the server began dropping new
connections; Hydra read those as connection errors and quit. The attack did not
"fail" because the system was secure — it failed because Hydra was too aggressive
and rate-limited itself into stopping.

**Impact:** Without understanding the mechanism, a defender could wrongly
conclude the host is safe. The real behaviour is a measurable, tunable penalty —
not an absolute block.

---

### Finding 3 — Speed vs. the wall (controlled test)

To confirm `PerSourcePenalties` was the *only* thing standing in the way, I
disabled it on the target and re-ran the attack at full speed.

```
# /etc/ssh/sshd_config
PerSourcePenalties no
```

```
sudo systemctl restart ssh
sudo sshd -T | grep -i penal      # verify: persourcepenalties no
hydra -l testuser -P /path/to/rockyou.txt -t 16 ssh://<target-ip>
```

**Analysis:** With the penalty gone, no connections were dropped and Hydra ran
cleanly. Throughput jumped from **~18 tries/min** (throttled, `-t 1`) to
**~220 tries/min** (`-t 16`, no penalty) — roughly a **12× speedup** — and the
weak test password was recovered.

**Impact:** The penalty system never made cracking *impossible*; it made it about
**12× slower**. That single ratio is the core result of the whole investigation.

---

## Root Cause

Password-based SSH is vulnerable to brute-force for a structural reason:

1. The credential (a password) lives in a guessable space, and public wordlists
   like `rockyou.txt` contain millions of real leaked passwords.
2. `MaxAuthTries` limits guesses per connection, but connections are unlimited.
3. Rate limiting (`PerSourcePenalties`, fail2ban) does not remove the
   vulnerability — it raises the *cost* of exploiting it.
4. A patient attacker who stays under the rate-limit threshold can still proceed;
   only the removal of the password factor entirely closes the door.

This is why throttling alone is never a complete answer — it changes the
economics of the attack, not its possibility.

---

## Remediation

### Technical

- **Use key-based authentication** (`PasswordAuthentication no`). A private key
  cannot be guessed by any wordlist at any speed, so brute-force dies at step one
  regardless of throttling. This is the root fix.
- **Keep `PerSourcePenalties` (or fail2ban) enabled** to block noisy, fast
  attackers automatically.
- **Disable direct root login** (`PermitRootLogin no`) so an attacker must guess
  both a valid username and its password.
- **Monitor auth logs** so a slow, low-and-slow attacker is still noticed by a
  human.

### Principle — defense in depth

No single layer is sufficient: rate limiting slows fast attacks but not patient
ones; key auth removes the password factor but should still be paired with
monitoring. Each layer covers a weakness in the one below it.

---

## Timeline

| Stage | Action                                             | Result                          |
| ----- | -------------------------------------------------- | ------------------------------- |
| 1     | Enable SSH, study service/process/signal behaviour | Baseline understanding          |
| 2     | Hydra `-t 16`, default target config               | Self-throttled, aborted         |
| 3     | Hydra `-t 4` / `-t 1`                               | Clean but slow; penalties observed |
| 4     | Inspect `sshd -T` → found `PerSourcePenalties`     | Defense mechanism identified    |
| 5     | Disable penalty, Hydra `-t 16`                      | ~220 tries/min, password recovered |
| 6     | Re-enable penalty, remove test user                | Lab returned to safe state      |

---

## Lessons Learned

- **`MaxAuthTries` is not a defense on its own** — new connections bypass it
  trivially.
- **A "failed" attack is not proof of security.** Understanding *why* an attack
  stopped (here, a specific penalty mechanism) matters more than the fact that it
  stopped.
- **Brute-force defense is economics, not walls.** The goal is to make guessing
  *not worth it*, not impossible — key-based auth is the only layer that closes
  the door completely.
- **Attacker and defender optimize the same trade-off.** The attacker balances
  speed against detection; the defender balances security against usability. Every
  `authfail:N` value is a point on that curve.

---

## Cleanup

Good practice: always return the lab to a safe state after testing.

```
# re-enable the built-in defense (remove the "PerSourcePenalties no" line), then:
sudo systemctl restart ssh

# remove the throwaway user; kill its lingering processes first if needed:
sudo pkill -9 -u testuser
sudo userdel -r testuser
```

`userdel` refuses to remove a user with a running process
(`user ... is currently used by process <PID>`) — the same process/signal
knowledge from Methodology step 1 applies: kill the process, then delete the user.

---

## Tools Used

- [THC-Hydra](https://github.com/vanhauser-thc/thc-hydra) — SSH brute-force
- `rockyou.txt` — password wordlist
- `sshd -T`, `systemctl`, `journalctl` — service inspection and logs
- `ps`, `pkill`, `kill` — process and signal management
- OpenSSH `PerSourcePenalties` — built-in per-source penalty defense

---

*This document is a personal technical write-up created for educational and
portfolio purposes. All testing was performed on systems I own and control.*
