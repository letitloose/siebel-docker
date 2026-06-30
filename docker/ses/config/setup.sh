#!/bin/bash
chown -R oracle /mnt/Siebel_Enterprise_Server
chgrp -R oinstall /mnt/Siebel_Enterprise_Server
chown -R oracle /siebel
chgrp -R oinstall /siebel

/mnt/Siebel_Enterprise_Server/Disk1/install/runInstaller.sh \
    -silent \
    -responseFile /config/ses.rsp \
    -invPtrLoc /config/oraInst.loc \
    -waitforcompletion \
    -showProgress \
    -oneclick
