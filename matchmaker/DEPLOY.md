# Deploy the matchmaker to Oracle Cloud (Free Tier)

The matchmaker is a tiny Godot **headless** WebSocket server. This guide sets it up on an
Oracle Cloud Free Tier VM so remote game clients can auto-discover open games.

> **Still true:** the matchmaker only does *discovery*. The game host's own port (7777) must be
> reachable on the host's router (port-forward / UPnP) for players to actually join. The VPS matchmaker
> does **not** relay game traffic.

---

## 1. Create the VM

1. Log in to the **Oracle Cloud Console** and go to **Compute → Instances → Create instance**.
2. Make sure **Region** is your **home region** (Always Free requires it).
3. For **Image**, pick a supported Linux (Ubuntu 24.04 or Oracle Linux 8).
4. **Shape:**
   - AMD → `VM.Standard.E2.1.Micro` (1/8 OCPU, 1 GB) — recommended, simplest.
   - Or Arm → `VM.Standard.A1.Flex` (from 1 OCPU/6 GB up to ~2 OCPU/12 GB free after the
     June 2026 cut). **If you pick Arm, you need the Godot `arm64` Linux build below.**
5. Generate/save your **SSH key pair** (private key stays on your PC).
6. Create the instance and note its **public IP**.

## 2. Open port 8080 (and 7777 if you'll host from the VPS)

1. **Networking → Virtual Cloud Networks →** your VCN → **Security Lists →** default list → **Add Ingress Rules**.
2. Add a rule for the matchmaker:
   - Source CIDR: `0.0.0.0/0`
   - IP protocol: TCP
   - Destination port: `8080`
3. (Optional) add the same for port `7777` if you want to host a game **from the VPS** itself.

> Note: the cloud **Security List** applies even though `godot` will also bind locally. This is the
> firewall that actually matters for remote clients.

## 3. Connect & install Godot headless

```bash
ssh -i ~/.ssh/your_key.pem ubuntu@<VPS_PUBLIC_IP>
```

Install Godot 4 Linux (match the shape):

```bash
# x86_64 (for E2.1.Micro AMD)
cd /tmp
wget https://github.com/godotengine/godot/releases/download/4.6-stable/Godot_v4.6-stable_linux.x86_64.zip
unzip Godot_v4.6-stable_linux.x86_64.zip
sudo install -m755 Godot_v4.6-stable_linux.x86_64 /usr/local/bin/godot

# ARM (for A1.Flex Arm) — use the .arm64 zip instead:
# wget https://github.com/godotengine/godot/releases/download/4.6-stable/Godot_v4.6-stable_linux.arm64.zip
# sudo install -m755 Godot_v4.6-stable_linux.arm64 /usr/local/bin/godot

godot --version   # sanity check
```

> If a newer patch like 4.6.3 is out, swap `4.6-stable` for that tag. Any recent 4.x works for the
> matchmaker — it only uses `TCPServer`/`WebSocketPeer`.

## 4. Put the matchmaker on the server

Option A — git clone the whole repo:

```bash
sudo mkdir -p /opt && cd /opt
sudo git clone https://github.com/ryguy15809/test-project-.git matchmaker
```

Option B — copy just the folder from your PC:

```bash
scp -i ~/.ssh/your_key.pem -r matchmaker ubuntu@<VPS_PUBLIC_IP>:/opt/
```

Either way the code should end up at `/opt/matchmaker` with `project.godot` + `matchmaker.gd`.

## 5. Run it with systemd (keeps it alive + restarts on boot)

```bash
# dedicate a non-root user
sudo useradd -r -m -d /home/matchmaker -s /usr/sbin/nologin matchmaker

# install the unit file
sudo cp /opt/matchmaker/matchmaker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matchmaker

# check it's up
sudo systemctl status matchmaker
journalctl -u matchmaker -f        # watch the live log
```

You should see `Matchmaker listening on port 8080` in the log and a **successful (active)**
status. The service restarts automatically if it crashes and starts on boot.

## 6. Point the game at it

In the game ([node_2d.gd](node_2d.gd#L12)), set:

```
matchmaker_url = "ws://<VPS_PUBLIC_IP>:8080"
```

(e.g. via the exported script property on the root `Node2D`, or by editing the default.)

## 7. Quick sanity test

From your PC (game) press **1v1** → it should connect to the matchmaker and, if it's the only
player, transition to **hosting** and register. Check the server log:

```bash
journalctl -u matchmaker -f   # look for "Registered host <ip>:7777"
```

Then run a second instance: it should print `Joining open server <ip>:7777` and connect to the host.

---

### Troubleshooting
- **No matchmaker connection from game** → confirm `matchmaker_url` uses `ws://` (not `wss://`), the
  VPS IP is correct, and Security List allows TCP 8080.
- **`out of host capacity`** when creating the VM → try another availability domain or retry later.
- **Idle reclaim** → Oracle may stop an idle VM after 7 days. With the service enabled you just
  `ssh` in and `sudo systemctl start matchmaker` to bring it back.
