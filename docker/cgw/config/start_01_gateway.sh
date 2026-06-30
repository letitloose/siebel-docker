#!/bin/sh
source ~/.bash_profile \
&& source /siebel/cgw/applicationcontainer_internal/bin/setenv.sh \
&& /siebel/cgw/applicationcontainer_internal/bin/startup.sh \
&& sleep 10 \
&& source /siebel/cgw/applicationcontainer_internal/bin/setenv.sh \
&& source /siebel/cgw/gtwysrvr/siebenv.sh \
&& /siebel/cgw/gtwysrvr/bin/list_ns \
&& /siebel/cgw/gtwysrvr/bin/start_ns
