#!/bin/sh
source ~/.bash_profile \
&& source /siebel/mde/siebsrvr/siebenv.sh \
&& srvrmgr /g @@MDE_HOSTNAME@@.@@PKI_DOMAIN@@:@@GW_TLS_PORT@@ /u @@AI_USERNAME@@ /p ${AI_USER_PWD} /e @@SIEBEL_ENTERPRISE@@
