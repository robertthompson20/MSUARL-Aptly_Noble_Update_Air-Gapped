# Aptly Monthly Mirror Pipeline (Ubuntu Noble)

This repository contains scripts and configuration to maintain an air-gapped Ubuntu 24.04 `noble` mirror using upstream Aptly.

The design supports:

- Mirroring and publishing once per month
- Distributions: `noble`, `noble-updates`, `noble-security`
- All components (`main`, `restricted`, `universe`, `multiverse`) merged into a single published component: `main`
- Use in an air-gapped environment with clients configured as `[trusted=yes]`
- Proxmox LXC clients for testing

---

## 0. Files in This Repo

```text
├── aptly-clean.sh
├── aptly.conf.example
├── create-aptly-mirror.sh
├── readme.md
├── v2-aptly-update-publish.sh
└── validate-aptly-publish.sh
```

### 0.1 `create-aptly-mirror.sh`

Creates the initial mirrors and performs the first mirror updates:

- `ubuntu-noble` -> `noble` with `main restricted universe multiverse`
- `ubuntu-noble-updates` -> `noble-updates` with `main restricted`
- `ubuntu-noble-security` -> `noble-security` with `main restricted`

Run this once during initial setup, or again only if you intentionally destroy and rebuild mirrors.

### 0.2 `v2-aptly-update-publish.sh`

- Checks whether mirrors are older than 24 hours and updates only if needed
- Creates new date-stamped snapshots: `ubuntu-noble-YYYYMMDD`, `ubuntu-noble-YYYYMMDD-updates`, and `ubuntu-noble-YYYYMMDD-security`
- Performs the initial publish if no publishes exist yet
- Uses `aptly publish switch` on later runs
- Publishes everything under a single component: `main`

This is the main monthly workflow script.

### 0.3 `validate-aptly-publish.sh`

- Confirms that each distribution (`noble`, `noble-updates`, `noble-security`) has both `Release` and `main/binary-amd64/Packages.gz`
- Checks that `neofetch`, `nvidia-driver-550`, and `ttf-mscorefonts-installer` appear under `main`

This validates that merged components are published correctly.

### 0.4 `aptly-clean.sh`

- Drops published repos: `ubuntu/noble`, `ubuntu/noble-updates`, and `ubuntu/noble-security`
- Drops snapshots whose names start with `ubuntu-noble`
- Leaves mirrors intact so packages are not re-downloaded

Use it only when:

- Publish state becomes inconsistent
- You change the publish layout or schema
- You want a clean rebuild of publishes and snapshots

---

## 1. Prerequisites - Install Upstream Aptly

Ubuntu's Aptly package (`aptly 1.5.0+ds1-2ubuntu0...`) is patched and has caused parsing issues and feature limitations in this workflow.

This setup expects Aptly to be installed from `repo.aptly.info` instead.

Keep your existing `/etc/aptly/aptly.conf` if you already have one. It defines `rootDir` and preserves your mirrors and snapshots. This repo also includes `aptly.conf.example` for new setups.

### 1.1 Remove Ubuntu's Aptly

```bash
sudo apt remove --purge aptly
```

Verify it is gone:

```bash
aptly version
# should say: command not found
```

### 1.2 Add the Official Aptly Repository

```bash
echo "deb http://repo.aptly.info/ squeeze main" | sudo tee /etc/apt/sources.list.d/aptly.list
curl -fsSL https://www.aptly.info/pubkey.txt | sudo tee /etc/apt/trusted.gpg.d/aptly.asc > /dev/null
```

### 1.3 Pin Aptly to Prefer Upstream and Block Ubuntu's Build

Positive pin for `repo.aptly.info`:

```bash
cat <<EOF | sudo tee /etc/apt/preferences.d/aptly.pref
Package: aptly
Pin: origin repo.aptly.info
Pin-Priority: 1001
EOF
```

Negative pin to block Ubuntu's Aptly:

```bash
cat <<EOF | sudo tee /etc/apt/preferences.d/deny-ubuntu-aptly.pref
Package: aptly
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
```

### 1.4 Update APT

```bash
sudo apt update
```

### 1.5 Verify APT Will Install Aptly from `repo.aptly.info`

```bash
apt-cache policy aptly
```

You should see something like:

- `Candidate: 1.5.0` from `http://repo.aptly.info squeeze/main`
- Ubuntu versions (`1.5.0+ds1-2ubuntu0...`) shown with priority `-1`

### 1.6 Install Upstream Aptly

```bash
sudo apt install aptly
```

Verify:

```bash
aptly version
apt-cache policy aptly
```

Ensure the installed (`***`) version comes from `repo.aptly.info`, not Ubuntu.

---

## 2. Aptly Configuration (`aptly.conf.example`)

This repo includes a reference config: `aptly.conf.example`.

It is tuned for:

- Root directory: `/path/to/aptly` (replace with your local Aptly storage path)
- Architecture: `amd64` only
- Fast parallel downloading
- No GPG signing or verification
- Client access via `[trusted=yes]`
- Modern pool layout

Copy it into place:

```bash
sudo cp aptly.conf.example /etc/aptly/aptly.conf
sudo chown root:root /etc/aptly/aptly.conf
sudo chmod 644 /etc/aptly/aptly.conf
```

All scripts default to `/etc/aptly/aptly.conf`, but you can override that with `APTLY_CONFIG=/path/to/aptly.conf` if your config lives elsewhere. The validation script also derives `rootDir` from that config automatically, or you can override it with `APTLY_ROOT_DIR=/path/to/aptly`.

Check that Aptly sees it:

```bash
aptly -config=/etc/aptly/aptly.conf mirror list
```

---

## 3. First-Time Setup Workflow

Use this section once per environment.

### 3.1 Ensure Aptly Is Installed and Configured

- Upstream Aptly installed
- `/etc/aptly/aptly.conf` deployed

### 3.2 Create Mirrors

```bash
sudo ./create-aptly-mirror.sh
```

This creates and updates:

- `ubuntu-noble`
- `ubuntu-noble-updates`
- `ubuntu-noble-security`

You should then see:

```bash
aptly -config=/etc/aptly/aptly.conf mirror list
```

### 3.3 Run the Monthly Script for the First Publish

```bash
sudo ./v2-aptly-update-publish.sh
```

On the first run, this script will:

- Update mirrors if needed
- Create snapshots
- Detect that no publishes exist yet
- Perform the initial publish for `noble`, `noble-updates`, and `noble-security`

You can confirm with:

```bash
aptly -config=/etc/aptly/aptly.conf publish list
```

### 3.4 Validate the Published Repo

```bash
sudo ./validate-aptly-publish.sh
```

If all checks show `[OK]`, the mirror is ready for use and export into the air-gapped environment.

---

## 4. Monthly Maintenance Workflow

After first-time setup, the monthly process is simple.

### 4.1 Run Monthly Update and Publish

```bash
sudo ./v2-aptly-update-publish.sh
```

- Updates mirrors only if they are older than 24 hours
- Creates new snapshots with the current date
- Uses `aptly publish switch` to move `noble`, `noble-updates`, and `noble-security` to the new snapshots

### 4.2 Validate

```bash
sudo ./validate-aptly-publish.sh
```

If validation passes, the monthly update is complete.

### 4.3 Recover from Publish Issues

```bash
sudo ./aptly-clean.sh
sudo ./v2-aptly-update-publish.sh
sudo ./validate-aptly-publish.sh
```

This rebuilds the publish and snapshot layer while preserving mirrors and the package pool.

---

## 5. Client Configuration

On each client that should consume the mirror:

```bash
cat <<EOF | sudo tee /etc/apt/sources.list.d/noble-offline.list
deb [trusted=yes] http://<server-ip>:8888/ubuntu noble main
deb [trusted=yes] http://<server-ip>:8888/ubuntu noble-updates main
deb [trusted=yes] http://<server-ip>:8888/ubuntu noble-security main
EOF

sudo apt update
```

Replace `<server-ip>` with the Aptly server IP, for example `192.168.200.251`.

Quick test:

```bash
apt policy neofetch
sudo apt install neofetch
```

If that succeeds and shows `noble/main` from your mirror, the merged-component setup is working correctly.

---

## 6. Notes and Recommendations

- Do not manually delete files under `<rootDir>/public`; always use Aptly commands.
- Back up regularly: `<rootDir>/db`, `<rootDir>/pool`, and `/etc/aptly/aptly.conf`
- Mirrors matching `ubuntu-noble*` rarely need to be recreated; `create-aptly-mirror.sh` is for first-time setup only.
- Monthly operations should be driven by `v2-aptly-update-publish.sh` and `validate-aptly-publish.sh`
