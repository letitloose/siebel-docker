create tablespace siebel_data
   datafile '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/SIEBEL_DATA.DBF' size 2G
   autoextend on next 100M maxsize unlimited
logging
   extent management local
segment space management auto;

create tablespace siebel_index
   datafile '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/SIEBEL_INDEX.DBF' size 2G
   autoextend on next 100M maxsize unlimited
logging
   extent management local
segment space management auto;

create tablespace siebel_etl_data
   datafile '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/SIEBEL_ETL_DATA.DBF' size 2G
   autoextend on next 100M maxsize unlimited
logging
   extent management local
segment space management auto;

create tablespace edq_data
   datafile '/opt/oracle/oradata/ORCLCDB/ORCLPDB1/EDQ_DATA.DBF' size 2G
   autoextend on next 100M maxsize unlimited
logging
   extent management local
segment space management auto;

alter session set "_oracle_script" = true;
alter profile default limit
   password_verify_function null;
alter profile default limit
   password_reuse_max unlimited;
alter profile default limit
   password_reuse_time unlimited;
alter profile default limit
   password_life_time unlimited;

drop role sse_role;
drop role tblo_role;

create role sse_role;
grant create session to sse_role;

create role tblo_role;
grant alter session,
   create cluster,
   create database link,
   create indextype,
   create operator,
   create procedure,
   create sequence,
   create session,
   create synonym,
   create table,
   create trigger,
   create type,
   create view,
   create dimension,
   create materialized view,
   query rewrite,
   on commit refresh
to tblo_role;

create user siebel identified by siebel20ax3tmy;
grant tblo_role to siebel;
grant sse_role to siebel;
alter user siebel
   quota 0 on system
   quota 0 on sysaux;

alter user siebel
   temporary tablespace temp;
alter user siebel
   quota unlimited on siebel_data;

create user sadmin identified by sadmin20ax3tmy;
grant sse_role to sadmin;
alter user sadmin
   default tablespace siebel_data;
alter user sadmin
   temporary tablespace temp;

create user ldapuser identified by ldapuser20ax3tmy;
grant sse_role to ldapuser;
alter user ldapuser
   default tablespace siebel_data;
alter user ldapuser
   temporary tablespace temp;

create user guesterm identified by guesterm20ax3tmy;
grant sse_role to guesterm;
alter user guesterm
   default tablespace siebel_data;
alter user guesterm
   temporary tablespace temp;

create user guestcst identified by guestcst20ax3tmy;
grant sse_role to guestcst;
alter user guestcst
   default tablespace siebel_data;
alter user guestcst
   temporary tablespace temp;

alter session set "_oracle_script" = true;
alter profile default limit
   password_verify_function null;
alter profile default limit
   password_reuse_max unlimited;
alter user siebel
   quota unlimited on siebel_data;
alter user sadmin
   quota unlimited on siebel_data;

grant unlimited tablespace to siebel;
grant unlimited tablespace to sadmin;