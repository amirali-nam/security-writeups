# Counterfeit Flash Storage Investigation & Analysis

**Author:** Amirali
**Date:** August 2026
**Category:** Hardware Analysis / Consumer Fraud Detection

---

## Executive Summary

I purchased two flash storage devices from an online marketplace, both advertised
as high-capacity products (a "1TB" microSD card and a "64TB" USB drive). Using
free, open-source disk-verification tooling on Linux, I confirmed that **both
devices were counterfeit**: their firmware was modified to report a fake capacity
to the operating system, while their real usable storage was a tiny fraction of
what was advertised.

This write-up documents the detection methodology, the technical findings with
proof, the underlying mechanism of the fraud, and the remediation steps taken to
recover the payments.

| Device | Advertised | Actual Usable | Verdict |
|--------|-----------|---------------|---------|
| Lenovo microSD | 1 TB | 0 bytes (damaged) | Counterfeit |
| Metal USB 3.2 | 64 TB | 7.07 GB | Counterfeit |

---

## Background

"Fake capacity" flash drives are a widespread form of consumer fraud. The devices
use a real but small memory chip (e.g. 8–64 GB) combined with modified firmware
that lies to the host system, reporting a capacity far larger than what physically
exists. Everything appears to work normally until the user writes past the real
capacity — at which point new data silently overwrites old data or is lost
entirely, with no error shown.

Because the fake capacity is baked into the controller firmware, standard tools
like Windows Disk Management or a normal format **cannot** reveal the real size;
they trust whatever the firmware reports.

---

## Methodology

The investigation used three stages of tooling:

### 1. Initial screening — H2testw (Windows)
`H2testw` writes test data across the entire *reported* capacity and then verifies
it can be read back. On a fake device it fails as soon as it passes the real
capacity. It also exposed an absurd reported size, which was the first red flag.

### 2. Real-capacity probing — f3probe (Linux)
`f3probe` (part of the `f3` — "Fight Flash Fraud" — suite) performs a destructive
read/write probe to find exactly where the real memory ends, independent of what
the firmware claims.

```bash
sudo apt install f3
sudo umount /dev/sdX1          # unmount first
sudo f3probe --destructive --time-ops /dev/sdX
```

### 3. Repair attempt — f3fix / fdisk / diskpart
`f3fix` can create a partition limited to the *real* capacity so the device
becomes safely usable at its true size. `fdisk` (Linux) and `diskpart` (Windows)
were used to rebuild the partition table.

> ⚠️ Note: `--destructive` erases the device. Only run it on hardware you own and
> have no data on.

---

## Findings

### Finding 1 — USB Drive: "64TB" → 7.07 GB (Counterfeit)

**f3probe output (key lines):**

```
Bad news: The device '/dev/sda' is a counterfeit of type limbo

Device geometry:
         *Usable* size: 7.07 GB (1853435 blocks)
        Announced size: 61.04 TB (16384000000 blocks)
                Module: 64.00 TB (2^46 Bytes)
```

**Analysis:** The firmware announced ~61 TB while the real usable memory was only
**7.07 GB** — roughly **0.01%** of the advertised capacity. `f3probe` classified
it as a *"limbo"* type counterfeit (writes past the real capacity wrap around and
corrupt existing data).

**Impact:** Any file written past ~7 GB would be silently corrupted. A user
storing important data would believe it was saved while it was actually
destroyed.

---

### Finding 2 — microSD Card: "1TB" → damaged / 0 bytes (Counterfeit)

**f3probe output (key lines):**

```
Bad news: The device '/dev/sda' is damaged

Device geometry:
         *Usable* size: 0.00 Byte (0 blocks)
        Announced size: 999.02 GB (2095106048 blocks)
                Module: 1.00 TB (2^40 Bytes)
```

Later, on Windows:

```
DiskPart has encountered an error: Data error (cyclic redundancy check).
```

**Analysis:** The card announced ~999 GB but returned **0 usable bytes**. The
CRC (cyclic redundancy check) error confirmed physical corruption of the flash —
the device was not only fake but had failed entirely. It could not be repaired
or salvaged even at a reduced size.

**Impact:** Total data loss. The device is unusable.

---

## Root Cause

Both devices are examples of **firmware-level capacity spoofing**:

1. A small, cheap memory chip is installed (real size ~7 GB / failed on the SD).
2. The controller firmware is reprogrammed to report a large fake capacity to the
   host.
3. The OS trusts the firmware and displays the fake size.
4. The fraud is invisible until data is written past the real capacity.

This is why high speeds or a passing quick-format do **not** prove authenticity —
the small real chip can genuinely be fast, and the OS never checks the firmware's
honesty.

---

## Remediation

### Technical
- Use `f3probe` / `H2testw` to verify **any** new flash device before trusting it.
- If a device is fake-but-functional, `f3fix` can cap it to the real size.
- A CRC / "damaged" result means the device is dead — discard it.

### Consumer / Financial
- Buy flash storage only from reputable brands (Samsung, SanDisk, Kingston)
  through official channels. Capacities like "64TB microSD" do not exist.
- When defrauded, escalate through the **payment provider** (e.g. Klarna,
  card chargeback), not only the marketplace — buyer protection there is stronger
  and can pause/refund the payment even when the seller disappears.
- Preserve evidence: tool output, order snapshots, and support chat logs.

---

## Timeline

| Date | Event |
|------|-------|
| Jul 2026 | Purchased both devices |
| Aug 2026 | H2testw flagged impossible reported capacity |
| Aug 2026 | f3probe confirmed both as counterfeit |
| Aug 2026 | Repair attempts (f3fix / fdisk / diskpart) |
| Aug 2026 | Disputes filed via marketplace + Klarna |
| Aug 2026 | microSD fully refunded; USB case escalated |

---

## Lessons Learned

- Firmware can lie to the operating system; never trust reported capacity alone.
- The right tool for the job matters — `f3probe` answered in minutes what a
  24-hour `H2testw` write test only hinted at.
- Solid evidence beats every workaround: a clear, documented technical proof was
  what moved the dispute forward.

---

## Tools Used

- [f3 (Fight Flash Fraud)](https://github.com/AltraMayor/f3) — `f3probe`, `f3fix`
- H2testw — capacity verification (Windows)
- `fdisk`, `diskpart`, `mkfs.fat` — partition management
- CrystalDiskInfo — SMART health checks

---

*This document is a personal technical write-up created for educational and
portfolio purposes.*
