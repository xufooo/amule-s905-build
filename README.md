# aMule cloud build (Ubuntu 18.04 arm64)

Builds `amuled` + `amuleweb` + `amulecmd` (daemon+web, no GUI) on GitHub
Actions for the S905 box running Ubuntu 18.04 (glibc 2.27).

## Build

Actions → **Run workflow** (defaults to aMule 3.0.1; set `amule_version`
for newer tags). On success a GitHub Release is published automatically —
download the latest tarball from the **Releases** page.

## Deploy on the box

```bash
# 18.04 is EOL; point apt at the old-releases archive first
sudo sed -i 's|ports.ubuntu.com/ubuntu|old-releases.ports.ubuntu.com/ubuntu|g' /etc/apt/sources.list
sudo apt update && sudo apt install -y libglib2.0-0 libcurl4 libreadline7 libpng16-16 zlib1g

sudo tar xzf aMule-*.tar.gz -C /

# one-time setup, as the user the service will run as (root by default)
sudo /opt/aMule/amuled            # generates the config; Ctrl-C after a few seconds
sudo cp -r /opt/aMule/share/amule/webserver /root/.aMule/
sudo nano /root/.aMule/amule.conf # [ExternalConnect] AcceptExternalConnections=1
                                  # ECPassword=<md5 of the EC password>
sudo /opt/aMule/amuleweb -P <EC password> -A <web admin password> -w   # writes remote.conf

# install the bundled units and start
sudo cp /opt/aMule/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now amuled amuleweb
# open http://<box-ip>:4711
```

To run unprivileged instead: add `User=<name>` to both units, then do the
one-time setup above as that user (its `~/.aMule`).
