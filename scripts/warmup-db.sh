#!/bin/bash
# Pre-warms the Oracle buffer cache so the first user doesn't feel the
# cold start. Marks small config tables as CACHE (MRU priority, survives
# memory pressure), then scans every SIEBEL table to pull its blocks in.
# Runs in background from start.sh and restart.sh — takes 5-15 minutes.

export MSYS_NO_PATHCONV=1
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

echo "==> [warmup] Marking hot config tables as CACHE..."
docker compose exec -T oracle19c \
    sqlplus -s sys/"${ORACLE_PWD}"@//localhost:1521/ORCLPDB1 as sysdba << 'SQL'
ALTER TABLE siebel.s_app_ver  CACHE;
ALTER TABLE siebel.s_sys_pref CACHE;
ALTER TABLE siebel.s_resp     CACHE;
ALTER TABLE siebel.s_role     CACHE;
ALTER TABLE siebel.s_appl_emp CACHE;
ALTER TABLE siebel.s_user     CACHE;
ALTER TABLE siebel.s_postn    CACHE;
EXIT;
SQL

echo "==> [warmup] Scanning all SIEBEL tables into buffer cache (this takes a while)..."
docker compose exec -T oracle19c \
    sqlplus -s sys/"${ORACLE_PWD}"@//localhost:1521/ORCLPDB1 as sysdba << 'SQL'
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
  v_count NUMBER;
  v_done  NUMBER := 0;
  v_total NUMBER;
BEGIN
  SELECT count(*) INTO v_total FROM dba_tables WHERE owner = 'SIEBEL';
  FOR t IN (SELECT table_name FROM dba_tables
            WHERE  owner = 'SIEBEL'
            ORDER BY blocks DESC NULLS LAST) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM siebel.' || t.table_name INTO v_count;
      v_done := v_done + 1;
      IF MOD(v_done, 100) = 0 THEN
        DBMS_OUTPUT.PUT_LINE('[warmup] ' || v_done || '/' || v_total || ' tables scanned');
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('[warmup] Complete: ' || v_done || '/' || v_total || ' tables in buffer cache.');
END;
/
EXIT;
SQL
