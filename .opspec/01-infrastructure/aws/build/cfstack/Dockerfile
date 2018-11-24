FROM ubuntu:bionic

WORKDIR /root
VOLUME /root/.ssh

RUN DEBIAN_FRONTEND=noninteractive && \
    apt update -y && \
    apt install -y python-pip openssh-client wget gettext curl jq git && \
    pip install awscli && \
    find /usr/local \
           \( -type d -a -name test -o -name tests \) \
        -o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) \
        -exec rm -rf '{}' + && \
    apt autoremove && apt autoclean && \
    apt purge -y python-pip

CMD ["bin/make-cluster-nodes.sh"]
