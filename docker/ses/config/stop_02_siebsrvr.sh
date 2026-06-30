#!/bin/sh
source ~/.bash_profile \
&& source /siebel/ses/siebsrvr/siebenv.sh \
&& /siebel/ses/siebsrvr/bin/list_server all \
&& /siebel/ses/siebsrvr/bin/stop_server all \
&& /siebel/ses/siebsrvr/bin/stop_server all \
&& mwadm stop \
&& /siebel/ses/applicationcontainer_internal/bin/shutdown.sh
