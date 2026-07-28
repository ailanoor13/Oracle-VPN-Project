# Oracle Cloud VPN Project

Self-hosted VPN server on Oracle Cloud, built with Terraform and Ansible. Started as "I wanna play Roblox on university wifi" and turned into an actual excuse to learn cloud infrastructure properly instead of just clicking around a console.

Status: in progress. Updating this as I go instead of writing it all at the end, so it's got the real mess in it, not just the polished final result.

## Why this exists

Short version: my university's wifi blocks games, so Roblox doesn't run. Longer version: most of the free VPNs available are also blocked, hence I wanted to actually build my own, partly because it's more reliable/faster if it's mine, and partly because it turned into a genuinely good excuse to learn Terraform, cloud networking, and general "how does infrastructure actually work" stuff properly.

So yeah, the goal is real (get Roblox working on campus), but the point of doing it this way instead of the easy way is the learning.

## What this actually does

Spins up a cloud server on Oracle's free tier using Terraform (so it's all defined in code, not clicked together by hand). Uses Ansible to automatically configure that server: installs WireGuard, generates keys, writes the VPN config, starts the service, hardens SSH, and sets up the firewall. Runs WireGuard on that server (fast, modern VPN protocol). My laptop connects to it, tunnels traffic through, university wifi just sees encrypted noise instead of "this is Roblox."

## Goals for the full project

- [x] Terraform config for networking and the actual VM
- [x] Ansible to auto-configure the server (WireGuard install, SSH lockdown, fail2ban)
- [x] Client setup and connection test
- [ ] GitHub Actions so infra changes get reviewed (terraform plan) before anything actually applies
- [ ] Ansible Vault so no secrets/keys ever end up in this repo
- [ ] Basic monitoring dashboard (Netdata) so I can see bandwidth/uptime
- [ ] Actual threat model section, what this protects against, what it doesn't (spoiler: it's not protecting me from a nation-state, it's protecting me from campus IT blocking UDP traffic to Roblox)

## Progress log

### Networking and VM config written (Terraform)

main.tf sets up: a private network (VCN) for the server to live in, firewall rules (only SSH 22 and WireGuard UDP 51820 allowed in, everything else blocked), and an Always Free VM, Ubuntu 24.04, SSH key login only (no passwords).

Networking resources created successfully. VCN, gateway, route table, security list, subnet, all created fine on the first terraform apply.

### Ran into Oracle capacity issues on the free ARM shape

Running into this on terraform apply: Error 500-InternalError, Out of host capacity.

Turns out this is a genuinely common thing with Oracle's free tier ARM VMs, they're popular because they're free, so regions run out of available capacity fairly often, especially Tokyo apparently. Not something I broke, just Oracle being out of stock basically.

Wrote a small script (retry-apply.sh) that keeps trying terraform apply every few minutes until Oracle has room, instead of me manually re-running it a hundred times. Eventually just switched to the less popular x86 VM.Standard.E2.1.Micro Always Free shape instead of fighting ARM capacity. terraform apply went through clean on the first try after that. Lesson: "Always Free" means the resource tier is free forever, not that it's always available.

### VM created and reachable over SSH

Confirmed with terraform apply (1 added, 0 changed, 0 destroyed) and then SSH'd in directly to check.

### First Ansible playbook: installing and configuring WireGuard

Wrote wireguard.yml to automate the server setup instead of doing it by hand. It installs WireGuard, turns on IP forwarding, generates a keypair, writes the WireGuard config file, and starts the service.

Hit a real bug along the way: my first version of the playbook generated the private key and saved it to a file in two separate steps. On a second run, the "generate" step correctly skipped itself since the key file already existed, but the "save" step didn't know that, and it overwrote the real key with a leftover status message instead. Ended up corrupting the key file. Fixed it by combining key generation and saving into a single atomic shell command, so there's no in-between step that can go stale.

Deleted the corrupted key, reran the playbook, and this time it went through clean: real key generated, config written, WireGuard service started and enabled on boot. Verified with systemctl status wg-quick@wg0 and wg show, both looking correct.

### SSH hardening and fail2ban

Added ssh-harden.yml: disabled password login, disabled root login, installed and confirmed fail2ban is running. Regenerated the WireGuard private key at this point too, since an earlier version had gotten exposed during debugging.

### Phase 3: client setup and connect

Set up the Windows laptop as a WireGuard client using the official WireGuard app and connected it to the server.

Ran into a couple of errors here. First, WireGuard showed "Active" but almost no data was being received, and connecting killed general internet access. Fixed by allowing WireGuard's UDP port through the server's firewall. After that fix, the tunnel connected properly (handshake succeeded, data flowing both ways), but general internet still didn't work through the tunnel. Fixed by allowing the server to forward traffic between the VPN and the internet.

Once both were fixed, tested by checking whatismyipaddress.com while connected, it showed the server's IP (Oracle Corporation, Japan) instead of the home IP. Confirmed working. Also tested Roblox at home while connected, the app launched and ran fine through the tunnel.

## Tools used so far

Terraform, Ansible, Oracle Cloud Infrastructure (OCI CLI), WireGuard (server and official Windows client), fail2ban, WSL/Ubuntu

## What's next

- Move to Phase 4: Ansible Vault for secrets
- Then Phase 5: GitHub Actions CI/CD
- Keep this README updated as I go instead of dumping it all at the end

## Random lessons so far

Oracle's card verification during signup can actually charge you a small real amount even when it says "verification failed," happened to me, got it sorted through Oracle's support chat.

The free tier isn't infinite, "Always Free" just means the resource tier is free forever, not that it's always available. Good reminder that free ≠ unlimited/instant.

Automating a setup step doesn't automatically make it safe. A bug in an Ansible playbook can silently corrupt data just as easily as doing it wrong by hand. Worth actually verifying what a task does, not just that it says "changed" or "ok."

Same lesson showed up again with firewalls: a rule can be technically correct and still do nothing if it's sitting in the wrong order in the list. Order matters as much as content.
