#!/bin/bash
# Entrypoint for the ACF services in docker-compose.yml: runs the image's own startup script (the arguments), and
# in the background installs ACF's cfpm packages (ACF_PACKAGES, default "sqlserver": the built-in SQL Server
# driver) into the running server once its final start is done.
#
# Why not the image's installModules: the coldfusion2025:2025.0.14 image re-pushed on 2026-11-26 believes it is at
# update level 0 and drops installed packages whenever ColdFusion starts ("sqlserver package will not be deployed
# as it is not installed"), so a package only stays in if it goes in after the last start. The coldfusion2023:2023.0.26
# image re-pushed on 2026-11-27 is at update level 0 too. This runs on every container start, so a
# `docker compose restart` gets the package back. Installing an installed package is harmless.

install_packages() {
    # First boot: the startup script restarts ColdFusion at most once, then writes disableScripts. Later boots:
    # disableScripts is already there and ColdFusion just starts. Either way, wait for it to answer on 8500.
    until [ -e /opt/startup/disableScripts ] && (: <>/dev/tcp/127.0.0.1/8500) 2>/dev/null; do sleep 5; done
    sleep 10
    for pkg in ${ACF_PACKAGES:-sqlserver}; do
        echo "acf-start.sh: installing cfpm package $pkg"
        echo "install $pkg" | /opt/coldfusion/cfusion/bin/cfpm.sh
    done
    echo "acf-start.sh: cfpm packages installed"
}

install_packages &
exec "$@"
