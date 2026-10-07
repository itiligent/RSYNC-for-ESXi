---

# RSYNC for VMware ESXi



[Rsync](https://rsync.samba.org/) is a lightweight, proven tool for reliable file replication, migration, and backup. It is also a staple on Linux systems, but sadly VMware never included it with ESXi, perhaps favoring commercial backup solutions.

This project restores essential Linux functionality on VMware ESXi by providing a fully static and portable rsync build, enabling reliable host-to-host and datastore-to-datastore file replication.

---

### **Prebuilt Rsync Binaries:**

If you dont wan't to build your own, download here:
* Latest version: [rsync v3.4.1 for ESXi](https://github.com/itiligent/RSYNC-ESXi/blob/main/rsync-3.4.1)
---

### 🔨 Rsync Build Script Supported Platforms

Debian 13  |  Ubuntu 24  |  RHEL 9 & 10  |  CentOS 9 & 10  |  Fedora 42 & 43

---

### Building Your ESXi Compatible Rsync Binary
All build files are created in `$HOME/build-static`

**RedHat specific Notes:**
* The build script will first try to install the distro package `glibc-static`.
* If `glibc-static` is unavailable in the OS repo, the script automatically builds glibc-static and extracts it to $HOME/build-static.


1. On a fresh supported system, run the build script **(not as root or sudo)**:

   ```bash
   ./rsync-esxi-builder-multiOS.sh
   ```
2. Copy the compiled `rsync` binary from `$HOME/build-static/rsync/bin` to **all ESXi hosts**.
3. On each ESXi host, set execute permissions on the new rsync executable:

   ```bash
   chmod 755 /path/to/rsync
   ```
4. **From ESXi 8 onwards** you must manually permit execution of non-native binaries:

   ```bash
   esxcli system settings advanced set -o /User/execInstalledOnly -i 0
   ```

5. Enable the ssh service and change the Esxi firewall to permit sshClient connections:
   ```bash
   vim-cmd hostsvc/enable_ssh
   vim-cmd hostsvc/start_ssh
   esxcli network firewall ruleset set --ruleset-id=sshClient --enabled=true
   ```
   
6. Configure destination **RSA or EdDSA SSH keys** for passwordless host-to-host authentication.

---

### 💻 Companion Rsync-for-Esxi Replication Script

[This replication script](https://raw.githubusercontent.com/itiligent/RSYNC-for-ESXi/refs/heads/main/rsync-esxi.sh) is written in **POSIX-compliant shell** and supports replication between ESXi, BusyBox, and GNU/Linux systems.

The script provides:

* Reliable ESXi-to-ESXi or Linux-to-ESXi replication
* **Fast/Safe copy modes** for optimized transfer or reliability
* **Automatic failover and retries** on network or file errors
* **Checksum verification** for end-to-end data integrity
* **Detailed logging** for auditing and troubleshooting
* **Automatic cleanup** of orphan `rsync` processes
---

### 🚀 Getting started with the replication script

1. **Ensure an rsync binary is installed** on both source and destination ESXi hosts.
2. **Set up SSH keys** for passwordless ssh access from the source host to the destination host.
3. Configure script options for source | destination | rsync binary paths | private key | excludes (optional) 
4. **Choose your replication mode:**

   * **FAST**: `--fast` – quick copy for high bw, networked filesystems or CPU constrained (minimal verification) 
   * **SAFE**: `--safe` – slower but highly resilient, verifies all transferred data, can resume copy
5. **Optional flags:**

   * `--dry-run` → Test the replication without copying files
   * `--checksum` → Verify file integrity after transfer
   * `--checksum-type=<algo>` → Specify checksum algorithm (`xxh3`, `md5`, etc.)
   * `--no-excludes` → Copy all files regardless of exclude list
6. **Run the replication script:**

   ```bash
   ./rsync-host2-host.sh --safe --checksum
   ```
7. **Monitor the logs** for progress and errors. Logs are saved with timestamps in the configured log directory.
8. **Recover from failures:**

   * FAST mode automatically falls back to SAFE mode on errors or a user configurable timeout
   * Script will retry indefinitely (with user configurable retry intervals) until successful

---




