<cfscript>
// Runs every *Spec.cfc here and returns TestBox's JSON report (tests/integration/test_specs.py reads it)
setting showdebugoutput=false requesttimeout=120;
// Bundles listed explicitly: a directory scan needs TestBox's "globber" dependency, which only CommandBox installs
tb = new testbox.system.TestBox(bundles = [ "specs.OTelSpec", "specs.RequestLifecycleSpec" ], reporter = "json");
report = tb.run();
cfcontent(type = "application/json", reset = true);
writeOutput(report);
</cfscript>
