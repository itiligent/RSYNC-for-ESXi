#!/bin/bash
####################################################################################################
# Compile RSYNC as a static binary for ESXi
# YOU MUST BUILD THIS ON A CENTOS 7 SYSTEM
# Check for latest version on github link below.
####################################################################################################

# Instructions:
# 1. Install a minimal Centos 7 virtual machine & give yourself administrator rights at install
# 2. Copy this script to your Centos7 home directory
# 3. Make script executable: chmod +x rsync-builder-centos7.sh
# 4. Run the script (don't run as sudo, it will prompt for sudo): ./rsync-builder-centos7.sh

clear

# Prepare text output colours
GREYB='\033[1;37m'
LRED='\033[0;91m'
LGREEN='\033[0;92m'
LYELLOW='\033[0;93m'
CYAN='\033[0;36m'

NC='\033[0m' #No Colour

RSYNC_VERSION=v3.4.1

# Script header
echo -e "${GREYB}Rsync for ESXi static binary compiler."
echo -e ${CYAN}

if [[ $EUID -eq 0 ]]; then
    echo -e "${LRED}This script must NOT be run as root, it will prompt for sudo when needed.${NC}" 1>&2
    echo
    exit 1
fi

# Now that CentOS 7 is EOL we need to change the repo links
sudo sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/CentOS-*.repo
sudo sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/CentOS-*.repo
sudo sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/CentOS-*.repo
sudo yum check-update

# Install these first
sudo yum -y install epel-release git lz4-devel lz4-static openssl-static python3-pip python3-devel glibc-static \
popt-devel popt-static make automake gcc wget doxygen rpm-build

# Install these second
sudo yum -y install libzstd-devel libzstd libzstd-static xxhash-devel

# Install this third
python3 -mpip install --user commonmark

cd ~ 
mkdir ~/rpmbuild
wget https://dl02.fedoraproject.org/pub/archive/epel/7/SRPMS/Packages/x/xxhash-0.8.2-1.el7.src.rpm
rpm -ivh xxhash-*.el7.src.rpm
cd ~/rpmbuild/SPECS
rpmbuild -bp xxhash.spec
cd ~/rpmbuild/BUILD/xxHash-*/
sudo make install

cd ~
git clone https://github.com/WayneD/rsync.git
cd ~/rsync
git checkout $RSYNC_VERSION

cd ~/rsync
LIBS="-ldl" ./configure
make -B CFLAGS="-std=c99 -static"

echo -e "${LYELLOW}If build was successful, below output should state: 'not a dynamic executable'...${LGREEN}"
ldd $(pwd)/rsync || true
echo -e "${GREYB}The new rsync binary can be found in ~/rsync."
echo -e ${NC}
