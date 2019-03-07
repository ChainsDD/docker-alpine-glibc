ARG ALPINE_VERSION=3.8
ARG GLIBC_VERSION=2.28

FROM alpine:${ALPINE_VERSION} as glibc_download
ARG GLIBC_VERSION
ARG BASE_URL=https://ftp.gnu.org/gnu
ARG GLIBC=glibc-${GLIBC_VERSION}.tar.gz
ARG GLIBC_URL=${BASE_URL}/glibc/${GLIBC}
ARG GNU_KEYRING=gnu-keyring.gpg
ARG GNU_KEYRING_URL=${BASE_URL}/${GNU_KEYRING}
RUN apk add --no-cache curl gnupg && \
    curl -sSL ${GLIBC_URL} -o ${GLIBC} && \
    curl -sSL ${GLIBC_URL}.sig -o ${GLIBC}.sig && \
    curl -sSL ${GNU_KEYRING_URL} -o ${GNU_KEYRING} && \
    gpg --verify --keyring ./${GNU_KEYRING} ${GLIBC}.sig && \
    tar -xvzf ${GLIBC}

FROM ubuntu:16.04 as glibc_compile
ARG GLIBC_VERSION
ARG PREFIX_DIR=/usr/glibc-compat
COPY --from=glibc_download /glibc-${GLIBC_VERSION} /glibc/
WORKDIR /glibc-build
RUN apt-get update && \
    apt-get install -y build-essential openssl gawk bison && \
    /glibc/configure \
        --prefix=${PREFIX_DIR} \
        --libdir=${PREFIX_DIR}/lib \
        --libexecdir=${PREFIX_DIR}/lib \
        --enable-multi-arch \
        --enable-stack-protector=strong && \
    make && \
    make install && \
    tar --hard-dereference -zcf /glibc-bin-${GLIBC_VERSION}.tar.gz ${PREFIX_DIR} && \
    sha512sum /glibc-bin-${GLIBC_VERSION}.tar.gz > /glibc-bin-${GLIBC_VERSION}.sha512sum

FROM alpine:${ALPINE_VERSION} as glibc_apk_build
ARG GLIBC_VERSION
RUN apk add --no-cache alpine-sdk coreutils cmake libc6-compat && \
    adduser -G abuild -g "Alpine Package Builder" -s /bin/ash -D builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir /packages && \
    chown builder:abuild /packages
USER builder
RUN mkdir /home/builder/package
WORKDIR /home/builder/package
COPY --from=glibc_compile /glibc-bin-${GLIBC_VERSION}.* ./
COPY apkbuild/* ./
ENV REPODEST /packages
ENV ABUILD_KEY_DIR /home/builder/.abuild
RUN mkdir -p ${ABUILD_KEY_DIR} && \
    openssl genrsa -out ${ABUILD_KEY_DIR}\glibc-key.pem 2048 && \
    sudo openssl rsa -in ${ABUILD_KEY_DIR}\glibc-key.pem -pubout -out /etc/apk/keys/glibc.rsa.pub && \
    echo "PACKAGER_PRIVKEY=\"${ABUILD_KEY_DIR}/glibc-key.pem\"" > ${ABUILD_KEY_DIR}/abuild.conf && \
    sed -i "s/<pkgver>/${GLIBC_VERSION}/" APKBUILD && \
    sed -i "s/<glibc-sha512sum>/$(cat glibc-bin-${GLIBC_VERSION}.sha512sum | awk '{print $1}')/" APKBUILD && \
    abuild -r

FROM alpine:${ALPINE_VERSION}
ARG GLIBC_VERSION
ENV LANG="C.UTF-8"
COPY --from=glibc_apk_build /packages/builder/x86_64/glibc*.apk /tmp/
RUN apk add --allow-untrusted /tmp/*.apk && \
    rm -f /tmp/*.apk && \
    ( /usr/glibc-compat/bin/localedef --force --inputfile POSIX --charmap UTF-8 "$LANG" || true ) && \
    echo export LANG="$LANG" > /etc/profile.d/locale.sh
    
