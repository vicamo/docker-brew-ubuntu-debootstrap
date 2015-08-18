FROM scratch
ADD rootfs.tar.xz /

# https://github.com/vicamo/docker-brew-ubuntu-debootstrap/issues/3
RUN sed -i 's!main$!main universe!' /etc/apt/sources.list

CMD ["/bin/bash"]
