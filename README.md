# Security & Hardware Writeups

A collection of hands-on technical investigations, hardware analysis, and
security notes documenting real problems I've investigated and solved.

## Contents

- [Counterfeit Flash Storage Investigation](counterfeit-storage-investigation.md)
  Detecting and analyzing fake-capacity USB and microSD devices using `f3probe`
  on Linux — including the fraud mechanism, proof-of-concept output, and
  remediation.

- [SSH Brute-Force Attack & Defense Analysis](ssh-bruteforce-persourcepenalties.md)
  Attacking and defending SSH in an isolated lab — brute-force with Hydra, the
  built-in `PerSourcePenalties` defense, and the security-vs-usability trade-off.

- [Remote File Delivery & Display on a Lab Host](remote-file-delivery-and-display.md)
  Discovering a host by scan, transferring a file over a throwaway HTTP server, and
  rendering it on the target's physical monitor from a remote SSH session — including
  the X11 vs framebuffer distinction and a single-command automation script.

## About

Self-taught full-stack developer and security enthusiast, documenting real
technical problems from firmware analysis to network security. Each writeup
follows a professional structure: methodology, findings with evidence, root
cause, and remediation.

Writeups span both offensive and defensive perspectives — from hardware
forensics to network attack simulation and hardening.

## Tools & Topics
`f3` · `fdisk` · `diskpart` · `hydra` · `sshd` · `nmap` · `wget` · `fbi` · hardware forensics · consumer fraud detection · SSH hardening · brute-force defense · host discovery · file transfer · framebuffer display
