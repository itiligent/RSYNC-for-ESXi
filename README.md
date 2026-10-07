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






