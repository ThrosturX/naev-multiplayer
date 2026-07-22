# Oracle Cloud Always Free deployment

## Create the VM

1. In OCI, open **Compute → Instances → Create instance**.
2. Use Canonical Ubuntu 22.04 and an **Always Free eligible** shape. One Ampere
   A1 OCPU and 1 GB RAM is ample; use an E2.1.Micro if A1 capacity is not
   available.
3. Use a public subnet and leave **Automatically assign a public IPv4 address**
   enabled.
4. Add or download an SSH key and create the instance.
5. On the instance's subnet security list (or its network security group), add
   a stateful ingress rule with source `0.0.0.0/0`, protocol UDP, all source
   ports, and destination port `60939`. Keep SSH port 22 restricted to your own
   public address when practical.

## Install the service

On the local development machine, from the plugin repository, substitute the
downloaded key and VM public address:

```sh
export MP2P_KEY=/path/to/ssh-key.key
export MP2P_VM=203.0.113.10
chmod 600 "$MP2P_KEY"
ssh -i "$MP2P_KEY" ubuntu@"$MP2P_VM"
```

On the VM:

```sh
sudo apt update
sudo apt install -y lua5.1 liblua5.1-0-dev libenet-dev luarocks build-essential rsync
sudo luarocks --lua-version=5.1 install enet
lua5.1 -e 'require "enet"; print("lua-enet ready")'
exit
```

Back on the local development machine, copy the current worktree. This is
intentional because the directory changes may not have been pushed yet:

```sh
rsync -az --exclude=.git -e "ssh -i $MP2P_KEY" ./ ubuntu@"$MP2P_VM":/tmp/naev-multiplayer/
ssh -i "$MP2P_KEY" ubuntu@"$MP2P_VM"
```

On the VM again:

```sh
sudo install -d /opt/naev-multiplayer
sudo cp -a /tmp/naev-multiplayer/. /opt/naev-multiplayer/
sudo install -m 0644 /opt/naev-multiplayer/directory/multiplayer-directory.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now multiplayer-directory
sudo systemctl status --no-pager multiplayer-directory
sudo ss -lunp | grep 60939
```

If `sudo ufw status` reports that UFW is active, also run:

```sh
sudo ufw allow 60939/udp
```

Follow logs with:

```sh
sudo journalctl -u multiplayer-directory -f
```

## Configure and test Naev

Restart both Naev processes with the current plugin. In **Info → Multiplayer →
P2P Session Settings**, set **Directory** using Naev's space-separated input:

```text
203.0.113.10 60939
```

Use the VM's real public address, not the example above. A host should use a
fixed, publicly reachable UDP listen port. The directory discovers peers but
does not relay gameplay or provide NAT traversal, so that host port still has
to be forwarded through the host's router/firewall.

Start the fixed-port host first, enter a system, and wait two seconds. Then
enter the same system on the second peer without adding the host as a bootstrap
peer. The second peer should obtain the host solely from the OCI directory.
