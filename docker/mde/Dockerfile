ARG INSTANTCLIENT_IMAGE=ol8/instantclient/32bit:19.31
FROM ${INSTANTCLIENT_IMAGE}

ARG SIEBEL_VERSION=24.9
ARG SIEBEL_USER=oracle
ARG SIEBEL_GROUP=oinstall
ARG SIEBEL_UID=29263
ARG SIEBEL_GID=29263
ARG PKI_PWD
ARG PKI_DOMAIN=company.com
ARG SES_HTTP_PORT=5090
ARG SES_SHUTDOWN_PORT=5092
ARG SES_REDIRECT_PORT=5091
ARG AI_HTTP_PORT=6090
ARG AI_SHUTDOWN_PORT=6092
ARG AI_REDIRECT_PORT=6091
ARG AI_USERNAME=SADMIN
ARG AI_USER_PWD
ARG GW_TLS_PORT=2320
ARG SIEBEL_ENTERPRISE=dev01
ARG MDE_HOSTNAME=dev01mde01

COPY docker/mde/config/ /config/
COPY software/Siebel_Enterprise_Server /mnt/Siebel_Enterprise_Server/

RUN mkdir -p -m a+rwx /siebel/mde /siebel/oraInventory /stage \
    && groupadd -g ${SIEBEL_GID} ${SIEBEL_GROUP} \
    && useradd -m -g ${SIEBEL_GROUP} -G ${SIEBEL_GROUP} -u ${SIEBEL_UID} ${SIEBEL_USER} \
    && dnf -y update libstdc++.x86_64 \
    && dnf -y install \
        openssl \
        ncurses \
        hostname \
        binutils.x86_64 \
        csh \
        gcc-c++.x86_64 \
        gcc.x86_64 \
        glibc-devel.i686 \
        glibc-devel.x86_64 \
        glibc.i686 \
        glibc.x86_64 \
        ksh \
        libX11.i686 \
        libXau.i686 \
        libXext.i686 \
        libXi.i686 \
        libXi.x86_64 \
        libXrender.i686 \
        libXtst.i686 \
        libXtst.x86_64 \
        libaio-devel.i686 \
        libaio-devel.x86_64 \
        libaio.i686 \
        libaio.x86_64 \
        libgcc.i686 \
        libgcc.x86_64 \
        libnsl.i686 \
        libnsl.x86_64 \
        libstdc++-devel.i686 \
        libstdc++-devel.x86_64 \
        libstdc++.i686 \
        libstdc++.x86_64 \
        libxcb.i686 \
        make.x86_64 \
        sysstat.x86_64 \
        zlib.i686 \
        vim \
        procps-ng \
        telnet \
        java-1.8.0-openjdk-headless \
    && dnf -y update \
    && dnf clean all \
    && rm -rf /var/cache/yum/x86_64 /var/cache/yum/i686 \
    \
    # Generate self-signed keystore
    && PKI_DIR=/tmp/pki \
    && mkdir -p ${PKI_DIR}/keys ${PKI_DIR}/ca \
    && printf 'basicConstraints=CA:FALSE\nsubjectAltName=@alt_names\n[alt_names]\nDNS.1 = *.%s\n' "${PKI_DOMAIN}" > ${PKI_DIR}/hosts_fqdn.txt \
    && printf 'subjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always, issuer\nbasicConstraints = critical, CA:true\nkeyUsage = keyCertSign, cRLSign\n' > ${PKI_DIR}/v3.txt \
    && keytool -genkey -alias siebel \
        -keystore ${PKI_DIR}/keys/siebelkeystore.jks \
        -keyalg RSA -sigalg SHA256withRSA -keysize 2048 \
        -storepass "${PKI_PWD}" -keypass "${PKI_PWD}" \
        -dname "cn=*.${PKI_DOMAIN}" -validity 3650 \
    && keytool -certreq -alias siebel \
        -keystore ${PKI_DIR}/keys/siebelkeystore.jks \
        -file ${PKI_DIR}/keys/siebelkeystore.csr \
        -storepass "${PKI_PWD}" \
    && openssl req -newkey rsa:2048 -new \
        -keyout ${PKI_DIR}/ca/cakey.pem \
        -out ${PKI_DIR}/ca/careq.pem \
        -subj "/CN=siebel-ca" -sha256 -passout "pass:${PKI_PWD}" \
    && openssl x509 -signkey ${PKI_DIR}/ca/cakey.pem -req -days 3650 \
        -in ${PKI_DIR}/ca/careq.pem \
        -out ${PKI_DIR}/ca/caroot.cer \
        -extfile ${PKI_DIR}/v3.txt -sha256 -passin "pass:${PKI_PWD}" \
    && echo 1234 > ${PKI_DIR}/ca/serial.txt \
    && openssl x509 \
        -CA ${PKI_DIR}/ca/caroot.cer \
        -CAkey ${PKI_DIR}/ca/cakey.pem \
        -CAserial ${PKI_DIR}/ca/serial.txt \
        -req -in ${PKI_DIR}/keys/siebelkeystore.csr \
        -out ${PKI_DIR}/keys/siebelkeystoreCASigned.cer \
        -days 3650 -extfile ${PKI_DIR}/hosts_fqdn.txt -passin "pass:${PKI_PWD}" \
    && keytool -import -alias ca \
        -file ${PKI_DIR}/ca/caroot.cer \
        -keystore ${PKI_DIR}/keys/siebelkeystore.jks \
        -storepass "${PKI_PWD}" -keypass "${PKI_PWD}" -noprompt \
    && keytool -import -alias siebel \
        -file ${PKI_DIR}/keys/siebelkeystoreCASigned.cer \
        -keystore ${PKI_DIR}/keys/siebelkeystore.jks \
        -storepass "${PKI_PWD}" -keypass "${PKI_PWD}" \
    && cp ${PKI_DIR}/keys/siebelkeystore.jks /config/siebelkeystore.jks \
    \
    # Encrypt PKI password and AI admin password separately
    && PKI_ENCRYPTED=$(java -jar \
        /mnt/Siebel_Enterprise_Server/Disk1/stage/ext/jlib/EncryptString.jar \
        "${PKI_PWD}") \
    && AI_PWD_ENCRYPTED=$(java -jar \
        /mnt/Siebel_Enterprise_Server/Disk1/stage/ext/jlib/EncryptString.jar \
        "${AI_USER_PWD}") \
    \
    # Substitute all placeholders into the response file and srvrmgr script
    && sed -i \
        -e "s|@@PKI_PWD_ENCRYPTED@@|${PKI_ENCRYPTED}|g" \
        -e "s|@@AI_USER_PWD_ENCRYPTED@@|${AI_PWD_ENCRYPTED}|g" \
        -e "s|@@AI_USERNAME@@|${AI_USERNAME}|g" \
        -e "s|@@SES_HTTP_PORT@@|${SES_HTTP_PORT}|g" \
        -e "s|@@SES_SHUTDOWN_PORT@@|${SES_SHUTDOWN_PORT}|g" \
        -e "s|@@SES_REDIRECT_PORT@@|${SES_REDIRECT_PORT}|g" \
        -e "s|@@AI_HTTP_PORT@@|${AI_HTTP_PORT}|g" \
        -e "s|@@AI_SHUTDOWN_PORT@@|${AI_SHUTDOWN_PORT}|g" \
        -e "s|@@AI_REDIRECT_PORT@@|${AI_REDIRECT_PORT}|g" \
        /config/mde.rsp \
    && sed -i \
        -e "s|@@MDE_HOSTNAME@@|${MDE_HOSTNAME}|g" \
        -e "s|@@PKI_DOMAIN@@|${PKI_DOMAIN}|g" \
        -e "s|@@GW_TLS_PORT@@|${GW_TLS_PORT}|g" \
        -e "s|@@AI_USERNAME@@|${AI_USERNAME}|g" \
        -e "s|@@SIEBEL_ENTERPRISE@@|${SIEBEL_ENTERPRISE}|g" \
        /config/start_srvrmgr.sh \
    \
    # Run the Siebel silent installer
    && chown -R ${SIEBEL_USER}:${SIEBEL_GROUP} /mnt/Siebel_Enterprise_Server /siebel \
    && su ${SIEBEL_USER} -c "bash /config/setup.sh" \
    \
    # Clean up installer and temp files
    && rm -rf /mnt/Siebel_Enterprise_Server/ ${PKI_DIR} \
    && sleep 30 \
    && chmod -R 755 /siebel

ENV RESOLV_MULTI=off \
    LANG=en_US.UTF-8 \
    JAVA_OPTS="-Dfile.encoding=utf8" \
    LIBPATH=${LD_LIBRARY_PATH} \
    SIEBEL_UNIXUNICODE_DB=ORACLE

EXPOSE 6091 2322
