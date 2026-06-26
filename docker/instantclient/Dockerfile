# Oracle Instant Client 32-bit base image
# Per Oracle MOS Note 2197176.1
#
# Prerequisites: download oracle-instantclient*.i386.rpm files from
# https://www.oracle.com/database/technologies/instant-client/linux-x86-32-downloads.html
# and place them in this directory before building.

ARG OL_VERSION=8

FROM oraclelinux:${OL_VERSION}-slim

ARG ORACLE_IC_VERSION=19.25
ARG DB_HOST
ARG DB_PORT
ARG DB_SERVICE

COPY *.rpm /

RUN microdnf -y install \
        ksh \
        tcsh \
        glibc.i686 \
        libaio.i686 \
        dnf \
    && dnf -y install oracle-instantclient${ORACLE_IC_VERSION}*.i386.rpm \
    && dnf clean all \
    && rm -rf /var/cache/yum/x86_64 \
    && rm -rf /var/cache/yum/i686 \
    && rm /oracle-instantclient${ORACLE_IC_VERSION}*.rpm \
    && mkdir -p /config \
    && printf '%s =\n  (DESCRIPTION =\n    (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    (CONNECT_DATA =\n      (SERVER = DEDICATED)\n      (SERVICE_NAME = %s)\n    )\n  )\n' \
       "${DB_SERVICE}" "${DB_HOST}" "${DB_PORT}" "${DB_SERVICE}" > /config/tnsnames.ora \
    && chmod 777 /config/tnsnames.ora

ENV ORACLE_IC_VERSION=${ORACLE_IC_VERSION} \
    ORACLE_HOME=/usr/lib/oracle/${ORACLE_IC_VERSION}/client \
    TNS_ADMIN=/config/ \
    LANG=en_US.UTF-8

ENV LD_LIBRARY_PATH="/usr/lib/oracle/${ORACLE_IC_VERSION}/client/lib:${LD_LIBRARY_PATH}" \
    PATH="/usr/lib/oracle/${ORACLE_IC_VERSION}/client/bin:${PATH}"
