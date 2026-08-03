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
- [x] GitHub Actions so infra changes get reviewed (terraform plan) before anything actually applies
- [x] Ansible Vault so no secrets/keys ever end up in this repo
- [x] Basic monitoring dashboard (Netdata) so I can see bandwidth/uptime
- [x] Actual threat model section, what this protects against, what it doesn't (spoiler: it's not protecting me from a nation-state, it's protecting me from campus IT blocking UDP traffic to Roblox)

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

### Phase 4: Ansible Vault (secrets management)

Before setting up Vault, did a check of what secrets were lying around and found one already exposed: my Oracle tenancy OCID was hardcoded in main.tf and had already been pushed to the public repo. Not a "someone can break in" level secret, more like an account label, but still shouldn't have been sitting in plain code. Fixed it by moving it into terraform.tfvars (gitignored) and confirmed with terraform plan that nothing broke ("No changes").

Then actually set up Vault for real: created group_vars/vpn_server/vault.yml, an encrypted file storing the laptop's WireGuard public key, and updated wireguard.yml to pull it from there instead of hardcoding it.

Funniest bug of the whole project so far: ansible-vault create dropped me straight into vim to type the file contents, and I had zero idea vim doesn't let you just start typing. Spent a solid minute stuck before learning you need i for insert mode, Esc to stop, then :wq to save. A truly ancient rite of passage, apparently.

Confirmed it all worked by rerunning the playbook with --ask-vault-pass and getting failed=0, then reconnecting WireGuard on my laptop to make sure the tunnel still worked with the vault-sourced key.

### Phase 5: CI/CD with GitHub Actions

Set up GitHub to automatically run terraform plan every time I push, so I can see what would change before anything actually happens on Oracle. It only plans, never auto-applies, I still run terraform apply myself.

Built this as .github/workflows/terraform.yml, triggered on push to main. Since GitHub's servers run this (not my laptop), it needs to authenticate to Oracle without real credentials sitting in the code, so I added five GitHub Secrets pulled from my local OCI config: OCI_PRIVATE_KEY, OCI_FINGERPRINT, OCI_TENANCY_OCID, OCI_USER_OCID, OCI_REGION.

This phase had the most bugs back to back, three in a row:
- Found my local OCI private key file had gotten corrupted with garbage text appended after the real key (no line break, just mashed together). Caught it with tail, fixed with sed to chop the bad line off, then copied the clean version into GitHub.
- First real run got through authentication and even showed a plan, then failed looking for ~/.ssh/id_ed25519.pub. Made sense once I thought about it, that file only exists on my laptop, GitHub's runner is a brand new machine every time. Fixed by adding a sixth secret (SSH_PUBLIC_KEY, totally fine to store since public keys are meant to be public) and a workflow step that writes it to a file before Terraform runs.
- Pushing the workflow file itself got flat out rejected the first time: my Personal Access Token didn't have the special "workflow" permission GitHub requires for anything touching .github/workflows/. Generated a new token with that scope checked, push went through.

Confirmed it all actually worked by watching the Actions tab go from red X to a clean green checkmark, full terraform plan output and everything, using nothing but GitHub Secrets, no real credentials anywhere in the code.

### Phase 6: monitoring with Netdata

Wrote monitoring.yml to install Netdata via its official install script, same automated approach as everything else here. Deliberately did not expose the dashboard to the public internet, it only listens on 127.0.0.1, so viewing it means opening an SSH tunnel (ssh -L 19999:localhost:19999 ubuntu@SERVER_IP) and loading localhost:19999 in my own browser. No SSH access, no dashboard.

Confirmed it's actually collecting real data (thousands of metrics tracked), and got to watch the live network graph spike in real time the moment I turned the WireGuard tunnel on, genuinely satisfying to see the whole pipeline prove itself end to end: client connects, tunnel carries traffic, server sees it, monitoring shows it.

Small gotcha: turning the VPN on mid-session killed my already-open SSH tunnel, since it rewrote the routing table underneath it. Not a bug, just had to reconnect the tunnel after the VPN came up. Lesson: routing tables don't care about your feelings.

### Phase 7: threat model

What this actually protects against:
- University wifi identifying and blocking Roblox traffic specifically (by port, protocol, or domain), since WireGuard just looks like generic encrypted noise to anything inspecting the traffic
- Basic network-level traffic shaping/throttling aimed at games or specific apps

What this does NOT protect against, and was never meant to:
- A targeted attacker, nation-state, or anyone actually trying to hack into something. This is a single free-tier VM running one service for one person. It's not hardened against serious, motivated attackers, just against a university firewall doing pattern matching.
- My ISP or campus network seeing that I'm using a VPN at all. WireGuard hides what I'm doing, not that I'm doing something. Anyone watching network metadata could reasonably guess "this looks like VPN traffic," they just can't tell it's specifically Roblox.
- Full anonymity. This isn't Tor, it's one server I control, in my name, on my own cloud account. If someone really wanted to know it was me, they could.
- Anything happening on the server itself being 100% bulletproof forever. I did real hardening (SSH keys only, fail2ban, minimal open ports, no exposed monitoring dashboard), but "reasonably secured hobby VM" and "impenetrable fortress" are different things.

Why this tradeoff is fine:
The actual risk here is genuinely small, campus IT noticing unusual traffic and maybe asking questions, worst case. Nobody's coming after a college student's Roblox VPN with serious resources. So the hardening I did (SSH lockdown, fail2ban, Vault, no public monitoring) is less "defending against real threats" and more "practicing what real infrastructure security looks like," which was the actual point of the whole project.

## Tools used so far

Terraform, Ansible (incl. Ansible Vault), Oracle Cloud Infrastructure (OCI CLI), WireGuard (server and official Windows client), fail2ban, GitHub Actions, Netdata, WSL/Ubuntu

## What's next

All 7 planned phases are done. What's left is really just the real-world test: actually trying this on campus wifi, since everything so far has only been tested at home (where Roblox already works fine, so it never proved anything about the actual blocking problem). Once that's confirmed, this project's genuinely complete and ready to share.

## Random lessons so far

Oracle's card verification during signup can actually charge you a small real amount even when it says "verification failed," happened to me, got it sorted through Oracle's support chat.

The free tier isn't infinite, "Always Free" just means the resource tier is free forever, not that it's always available. Good reminder that free ≠ unlimited/instant.

Automating a setup step doesn't automatically make it safe. A bug in an Ansible playbook can silently corrupt data just as easily as doing it wrong by hand. Worth actually verifying what a task does, not just that it says "changed" or "ok."

Same lesson showed up again with firewalls: a rule can be technically correct and still do nothing if it's sitting in the wrong order in the list. Order matters as much as content.

Also apparently I will fight vim before I learn vim.
