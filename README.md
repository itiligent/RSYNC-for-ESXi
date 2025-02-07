# RSYNC for ESXi
### Build scripts for compiling rsync for use with VMware ESXi
Rsync is a mature Linux staple for reliably replicating files over imperfect or lower speed links. For data migration it is particularly useful for keeping track of data changes between systems during a staged migration, but it is equally useful as a backup or disaster recovery tool.

If you dont want to build your own (and you trust this repo), a prebuilt rsync executable is available here: [rsync v3.4.1 for ESXi](https://github.com/itiligent/RSYNC-for-ESXi/raw/main/rsync)

## Compile rsync with Centos 7 or Docker
You will need either:
- For source build, an instance of Centos 7 OS _[Get the Centos 7 ISO here]( https://buildlogs.centos.org/centos/7/isos/x86_64/)_
- For Docker build, Docker pre installed (any host OS). 

**To compile rsync natively within Centos 7:**
```
1a. chmod +x rsync-esxi-compiler.sh && ./rsync-esxi-compiler.sh
```  
**To compile rsync within a Docker container:**
```
1b. chmod +x rsync-esxi-compiler-docker.sh && ./rsync-esxi-compiler-docker.sh
```
   **Common completion steps:**
```
2. Copy the completed rsync binary to a *persistent* location in ESXi: e.g. any VMFS datastore or /productLocker/ are good locations
3. In ESXi set execute permissions on rsync: chmod 755 rsync
4. ESXi 8 only (By default ESXi 8 blocks execution of non-native binaries). 
          To temporarily override this restriction...:  esxcli system settings advanced set -o /User/execInstalledOnly -i 0
          To restore the default.....................:  esxcli system settings advanced set -o /User/execInstalledOnly -i 1
          To check status............................:  esxcli system settings advanced list -o /User/execInstalledOnly
```

## ESXi rsync examples:
### rsync via SSH (prompts for destination's password):
```
/productLocker/rsync -avurP --delete --progress /vmfs/volumes/source_path/* user@x.x.x.x:/destination_path/
```
### rsync via SSH with SSHkey authentication (no password prompt)

- SSH keys can be used to enable rsync to non interactively authenticate to the destination. Save the destination's private SSH key to a file in a *persistent* location and change the file's permissions with: `chmod 400 priv-key.txt` The below example uses SSH key auth to automatically login and begin sync (no password or other ssh prompts):
```
/productLocker/rsync -avurP --delete --progress -e "ssh -i /productLocker/priv-key.txt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" /vmfs/volumes/source_path/* user@x.x.x.x:/destination_path/
```

### rsync to a local (or USB) Datastore
See [here](https://github.com/itiligent/ESXi-Custom-ISO/blob/main/testlab-cheat-sheet.md#to-add-a-usb-backup-datastore-to-esxi) for instructions on adding a USB backup VMFS datastore.

    1. Establish a new USB VMFS backup datastore (or confirm space in an existing datastore)
    2. Create a backup destination folder on the destination datastore e.g. mkdir /vmfs/volumes/USB_datastore/full_backup_destination
    3. Modify the below command to suit:
    
    /vmfs/volumes/USB_destination_datastore/rsync -rltDv --delete --progress /vmfs/volumes/source_path/* /vmfs/volumes/USB_datastore/full_backup_destination

