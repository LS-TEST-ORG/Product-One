<cfsetting showDebugOutput="false">
<cfparam name="url.reporter" default="simple">
<cfscript>
    tb = new testbox.system.TestBox( directory = "tests.specs" );
    writeOutput( tb.run( reporter = url.reporter ) );
</cfscript>