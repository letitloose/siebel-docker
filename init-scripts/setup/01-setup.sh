#!/bin/bash
# Renders 01-setup.sql.template using values already present in the
# container's environment (passed through via the oracle19c service's
# env_file: .env) and runs it.
#
# This keeps the sadmin username/password and guestcst password derived
# from the same AI_USERNAME/AI_USER_PWD/SIEBEL_ANON_PWD values used by
# scripts/bootstrap-mde.sh and baked into the SAI/MDE images at build
# time, so there is a single source of truth instead of independently-set
# copies of the same credential.
#
# Renders to /tmp rather than back into the bind-mounted setup/ directory,
# so the rendered file (and the plaintext password it contains) never
# touches the host filesystem.

TEMPLATE="$(dirname "${BASH_SOURCE[0]}")/01-setup.sql.template"
RENDERED=/tmp/01-setup-rendered.sql

sed \
    -e "s|@@AI_USERNAME@@|${AI_USERNAME}|g" \
    -e "s|@@AI_USER_PWD@@|${AI_USER_PWD}|g" \
    -e "s|@@SIEBEL_ANON_PWD@@|${SIEBEL_ANON_PWD}|g" \
    "$TEMPLATE" > "$RENDERED"

sqlplus -s / as sysdba @"$RENDERED"

rm -f "$RENDERED"
