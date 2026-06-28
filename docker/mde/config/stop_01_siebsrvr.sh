#!/bin/sh
source ~/.bash_profile \
&& source /siebel/mde/siebsrvr/siebenv.sh \
&& /siebel/mde/siebsrvr/bin/list_server all \
&& /siebel/mde/siebsrvr/bin/stop_server all \
&& mwadm stop
