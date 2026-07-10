#!/bin/bash
# Runs once after 01-setup.sql, during first-start DB creation.
# Imports the SIEBEL schema from a Data Pump dump file placed in ./data/dumps/.

DUMP_FILE="${DUMP_FILE}"

if [ ! -f "/opt/oracle/dumps/${DUMP_FILE}" ]; then
    echo "ERROR: Dump file not found: /opt/oracle/dumps/${DUMP_FILE}"
    echo "Place the file in ./data/dumps/ and recreate the container."
    exit 1
fi

echo "Starting SIEBEL schema import from ${DUMP_FILE} ..."

export ORACLE_PDB_SID=ORCLPDB1

impdp \"sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba\" \
    SCHEMAS=SIEBEL \
    DIRECTORY=siebel_dumps \
    DUMPFILE="${DUMP_FILE}" \
    LOGFILE=impdp_siebel.log \
    TABLE_EXISTS_ACTION=REPLACE \
    PARALLEL="${IMPORT_PARALLEL:-1}"

echo "Import finished. Log: /opt/oracle/dumps/impdp_siebel.log"
