#!/bin/sh
source ~/.bash_profile \
&& source /siebel/ses/applicationcontainer_internal/bin/setenv.sh \
&& /siebel/ses/applicationcontainer_internal/bin/startup.sh \
&& sleep 10 \
&& source /siebel/ses/siebsrvr/siebenv.sh \
&& /siebel/ses/siebsrvr/bin/list_server all \
&& /siebel/ses/siebsrvr/bin/start_server all
