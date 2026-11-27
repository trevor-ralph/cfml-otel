<cfscript>
// Dev/CI only: installs ACF's built-in SQL Server driver, the cfpm "sqlserver" package, into the running server.
// The integration harness requests it on ACF once ColdFusion answers (tests/integration/harness.py). Not done at
// container start (installModules): the coldfusion2025:2025.0.14 image re-pushed on 2026-11-26 believes it is at
// update level 0 and drops installed packages whenever ColdFusion starts, so the package has to go in after the
// last start, and again after any restart. Installing an already-installed package is harmless.
setting showdebugoutput=false;
cfexecute(name = "/opt/coldfusion/cfusion/bin/cfpm.sh", arguments = "install sqlserver", timeout = 300,
    variable = "out", errorVariable = "err");
writeOutput(out & err);
</cfscript>
