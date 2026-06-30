#!/bin/sh
source ~/.bash_profile \
&& source /siebel/mde/applicationcontainer_internal/bin/setenv.sh \
&& source /siebel/mde/gtwysrvr/siebenv.sh \
&& /siebel/mde/gtwysrvr/bin/list_ns \
&& /siebel/mde/gtwysrvr/bin/start_ns
