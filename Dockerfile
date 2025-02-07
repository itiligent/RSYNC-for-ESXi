FROM centos:centos7

ARG RSYNC_VERSION=v3.4.1

# fix yum repo URLs for CentOS 7 EOL
RUN sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/CentOS-*.repo && \
sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/CentOS-*.repo && \
sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/CentOS-*.repo

RUN yum -y install \
epel-release \
git \
lz4-devel \
lz4-static \
openssl-static \
python3-pip \
python3-devel \
glibc-static \
popt-devel \
popt-static \
make \
automake \
gcc \
wget \ 
doxygen \
rpm-build

RUN yum -y install \
libzstd-devel \
libzstd \
libzstd-static \
xxhash-devel \
&& \
python3 -mpip install --user commonmark

RUN cd / && \ 
wget https://archives.fedoraproject.org/pub/archive/epel/7/SRPMS/Packages/x/xxhash-0.8.2-1.el7.src.rpm && \
rpm -ivh xxhash-*.el7.src.rpm && \
cd ~/rpmbuild/SPECS && \
rpmbuild -bp xxhash.spec && \
cd ~/rpmbuild/BUILD/xxHash-*/ && \
make install

RUN cd / && \
git clone https://github.com/RsyncProject/rsync.git && \
cd rsync && \
git checkout $RSYNC_VERSION
 
WORKDIR /rsync

RUN cd /rsync && \
LIBS="-ldl" ./configure && \
make -B CFLAGS="-static -std=c99"

RUN echo If build was successful, below output should state: 'not a dynamic executable' && \
ldd rsync || \
true

RUN ./rsync -V
