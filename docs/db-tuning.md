# Oracle DB Performance Tuning and Troubleshooting

Queries for diagnosing and tuning the Oracle 19c container. All commands assume you are exec'd into the container and connected via OS authentication:

```bash
docker exec -it <db-container-name> bash
sqlplus / as sysdba
```

Some queries targeting Siebel data need to switch into the PDB first:

```sql
ALTER SESSION SET CONTAINER = ORCLPDB1;
```

---

## Verify Memory Tuning Took Effect

After setting `ORACLE_SGA` / `ORACLE_PGA` and restarting, confirm the values are actually in use:

```sql
-- Current SGA layout
SELECT name, round(value/1024/1024/1024, 2) AS gb
FROM v$sgainfo
WHERE name IN ('Maximum SGA Size', 'Total SGA Size', 'Buffer Cache Size', 'Shared Pool Size')
ORDER BY 1;

-- Parameter settings (what's in SPFILE)
SELECT name, value
FROM v$parameter
WHERE name IN ('sga_max_size', 'sga_target', 'pga_aggregate_target')
ORDER BY 1;

-- Actual PGA in use right now
SELECT round(value/1024/1024/1024, 2) AS pga_allocated_gb
FROM v$pgastat
WHERE name = 'total PGA allocated';
```

**What to look for:** Buffer Cache Size should be close to `sga_target`. If it's still small (< 2 GB) after setting `ORACLE_SGA=12G`, the restart didn't apply — check that `ORACLE_SGA` was set before the container was first created (init scripts only run once).

---

## Diagnosing a CPU Spike

When the DB container pegs CPU during a query, check what Oracle is actually waiting on — CPU percentage alone doesn't tell you the bottleneck:

```sql
-- What are all non-idle sessions waiting for right now?
SELECT event, wait_class, count(*) AS sessions
FROM v$session_wait
WHERE wait_class != 'Idle'
GROUP BY event, wait_class
ORDER BY sessions DESC;
```

### Common wait events and what they mean

| Event | What's happening | What to do |
|---|---|---|
| `db file sequential read` | Single-block I/O — index lookup hit disk, not in cache | Normal on cold cache; goes away as cache warms. Persistent = consider more SGA or the index isn't selective |
| `db file scattered read` | Multi-block I/O — full table scan hitting disk | Bad news: something is doing a full scan. Check execution plan. May be stale stats or a missing index |
| `log file sync` | Waiting for a commit to flush to redo log | High commit rate. Not usually a Siebel issue unless doing bulk writes |
| `log file parallel write` | LGWR writing redo to disk | Disk I/O on the redo log location. On Docker this is on the same block volume as datafiles — not much to do |
| `resmgr:cpu quantum` | Oracle waiting for a CPU time slice | Genuinely CPU-bound. More OCPUs would help here |
| `enq: TX - row lock contention` | Sessions waiting on a locked row | A long-running transaction is blocking others |
| `buffer busy waits` | Multiple sessions competing for the same buffer | Usually resolves itself; if persistent, hot-block contention |
| `direct path read` | Reading directly from disk, bypassing buffer cache | Parallel query or large sort spilling to temp. Check PGA size |

---

## Buffer Cache Hit Ratio

Tells you what percentage of block reads are being served from memory vs. disk. A cold cache (e.g. right after a restart) will show a low ratio that climbs over time as data loads into memory.

```sql
SELECT round(
    (1 - (
        sum(CASE WHEN name = 'physical reads' THEN value END) /
        (sum(CASE WHEN name = 'db block gets' THEN value END) +
         sum(CASE WHEN name = 'consistent gets' THEN value END))
    )) * 100, 2
) AS buffer_cache_hit_pct
FROM v$sysstat;
```

**What to look for:** Above 95% is healthy for an OLTP workload. If it's 70–80% even after the cache has had time to warm (i.e. after several hours of use), the SGA may be too small to hold the working set. Below 95% right after a restart is normal — give it time.

---

## Find Slow SQL

When you know something is slow but not which query:

```sql
-- Top 10 SQL statements by total elapsed time since startup
SELECT
    sql_id,
    round(elapsed_time / 1000000, 1)                          AS total_elapsed_sec,
    executions,
    round(elapsed_time / greatest(executions, 1) / 1000000, 3) AS sec_per_exec,
    round(buffer_gets / greatest(executions, 1))               AS gets_per_exec,
    substr(sql_text, 1, 100)                                   AS sql
FROM v$sql
WHERE executions > 0
ORDER BY elapsed_time DESC
FETCH FIRST 10 ROWS ONLY;
```

**What to look for:** High `gets_per_exec` (logical reads per execution) suggests a full scan or a very non-selective query. High `sec_per_exec` on a statement with few executions is a one-off expensive query — worth looking at its execution plan.

Get the plan for a specific `sql_id`:

```sql
SELECT * FROM table(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'ALLSTATS LAST'));
```

A `FULL` operation on a large table in the plan is a full table scan — check whether an index exists and whether stats are current.

---

## See What's Running Right Now

```sql
-- Active sessions with their current wait event and SQL
SELECT
    s.sid,
    s.username,
    s.status,
    w.event,
    w.seconds_in_wait,
    substr(q.sql_text, 1, 100) AS sql
FROM v$session s
LEFT JOIN v$session_wait w ON s.sid = w.sid
LEFT JOIN v$sql q ON s.sql_id = q.sql_id
WHERE s.status = 'ACTIVE'
  AND s.username IS NOT NULL
ORDER BY w.seconds_in_wait DESC NULLS LAST;
```

---

## Statistics

Stale optimizer statistics cause Oracle to pick bad execution plans — often resulting in full table scans instead of index lookups. Stats should be gathered after the initial import and any major data change.

```sql
-- Switch to the PDB first
ALTER SESSION SET CONTAINER = ORCLPDB1;

-- Check when SIEBEL schema tables were last analyzed (oldest first)
SELECT table_name, last_analyzed, num_rows
FROM dba_tables
WHERE owner = 'SIEBEL'
ORDER BY last_analyzed NULLS FIRST
FETCH FIRST 20 ROWS ONLY;
```

Tables with `last_analyzed` null or very old are likely causing suboptimal plans. Regather all SIEBEL stats:

```sql
EXEC DBMS_STATS.GATHER_SCHEMA_STATS('SIEBEL', cascade => TRUE);
```

`cascade => TRUE` also gathers index statistics. Takes 10–30 minutes on a typical Siebel schema. Run it after the import and again if query plans seem to regress.

---

## Archivelog / FRA Health

The container runs with `ENABLE_ARCHIVELOG: true`, which means Oracle writes archived redo logs to the Fast Recovery Area. If the FRA fills up, Oracle will stop and refuse all writes.

```sql
-- FRA usage
SELECT
    name,
    round(space_limit / 1024 / 1024 / 1024, 1)    AS limit_gb,
    round(space_used / 1024 / 1024 / 1024, 1)     AS used_gb,
    round(space_used / space_limit * 100, 1)       AS pct_used
FROM v$recovery_file_dest;

-- How many archivelogs are accumulating
SELECT count(*), round(sum(blocks * block_size) / 1024 / 1024 / 1024, 2) AS gb
FROM v$archived_log
WHERE standby_dest = 'NO' AND deleted = 'NO';
```

**What to look for:** If `pct_used` climbs above 80%, archived logs are accumulating. For a dev environment that isn't doing backups, this just grows. The fix for a dev box is to periodically purge:

```sql
-- Connect to RMAN inside the container:
-- rman target /
-- DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-1';
```

Or mount the FRA on the Oracle data block volume (it's already there) and give the block volume more space.
