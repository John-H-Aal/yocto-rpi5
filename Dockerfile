FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Yocto Scarthgap host dependencies (docs.yoctoproject.org/5.0)
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc g++ build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    python3-subunit zstd liblz4-tool file locales libacl1 \
    lz4 python3-websockets bmap-tools mc \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Non-root user — Yocto refuses to run as root
RUN useradd -m -u 1000 -s /bin/bash yocto
USER yocto
WORKDIR /home/yocto

# Source the Yocto build environment and drop to an interactive shell.
# All layer repos must be mounted before running this container.
# See SETUP.md § Docker Quickstart.
ENTRYPOINT ["/bin/bash", "-c", \
    "cd /home/yocto && \
     source poky/oe-init-build-env build-rpi5 && \
     exec bash"]
