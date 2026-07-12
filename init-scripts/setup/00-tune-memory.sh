#!/bin/bash
# Sets Oracle SGA and PGA sizes before the schema import.
# Only activates when ORACLE_SGA or ORACLE_PGA are set in the environment.
# Without tuning, Oracle defaults to ~1.5 GB SGA regardless of available RAM,
# which causes slow query performance at runtime.
#
# SGA_MAX_SIZE requires a restart to take effect, so this script briefly
# shuts Oracle down and brings it back up before the import begins.

if [ -z "${ORACLE_SGA:-}" ] && [ -z "${ORACLE_PGA:-}" ]; then
    echo "ORACLE_SGA/ORACLE_PGA not set — skipping memory tuning (Oracle defaults apply)"
    exit 0
fi

SGA="${ORACLE_SGA:-12G}"
PGA="${ORACLE_PGA:-4G}"

echo "Tuning Oracle memory: SGA_MAX_SIZE=${SGA} SGA_TARGET=${SGA} PGA_AGGREGATE_TARGET=${PGA}"
echo "Oracle will restart briefly to apply SGA_MAX_SIZE — back up in ~30 seconds."

sqlplus -s / as sysdba << EOF
ALTER SYSTEM SET SGA_MAX_SIZE = ${SGA} SCOPE=SPFILE;
ALTER SYSTEM SET SGA_TARGET = ${SGA} SCOPE=SPFILE;
ALTER SYSTEM SET PGA_AGGREGATE_TARGET = ${PGA} SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
EOF

echo "Memory tuning complete: SGA=${SGA}, PGA=${PGA}"
