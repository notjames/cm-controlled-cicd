FROM alpine:latest
LABEL maintainer="Jim Conner <snafu.x@gmail.com>"

RUN apk update && \
    apk add --no-cache --virtual .build-deps py2-pip \
              alpine-sdk build-base  && \
    pip install awscli && \
    find /usr/local \
           \( -type d -a -name test -o -name tests \) \
        -o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) \
        -exec rm -rf '{}' + && \
    runDeps="$( \
        scanelf --needed --nobanner --recursive /usr/local \
                | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
                | sort -u \
                | xargs -r apk info --installed \
                | sort -u \
              )" && \
    apk add --virtual .rundeps $runDeps go python2 && \
    go get gopkg.in/mikefarah/yq.v2 && \
    wget -qO /usr/local/bin/kubectl \
      https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl && \
      chmod 755 /usr/local/bin/kubectl && \
    wget -qO /var/tmp/jo-1.1.tar.gz https://github.com/jpmens/jo/releases/download/v1.1/jo-1.1.tar.gz && cd /var/tmp && tar xfz jo-1.1.tar.gz && \
    cd jo* && ./configure && make && make install && \
    apk del .build-deps && \
    apk add openssh gettext bash curl jq git

RUN /usr/bin/go get gopkg.in/mikefarah/yq.v2

WORKDIR /var/tmp

RUN rm -rf jo*
COPY bin/* bin/
#COPY templates/ templates/

VOLUME /root/.ssh
#VOLUME /root/.aws

ENTRYPOINT ["bin/make-cluster-nodes.sh"]
