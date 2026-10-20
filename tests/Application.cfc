/*
    Application.cfc for the test suite.

    Lucee uses the nearest Application.cfc to the requested page, so this one stops the root
    Application.cfc (which only serves compare.cfm) from intercepting tests/runner.cfm.

    The tests only answer on loopback: the CI runner calls them on the same machine, and nobody
    else should be able to run them if this folder is ever deployed.
*/
component output=false {

    this.name = "ProductOneTests_" & hash( getCurrentTemplatePath() );
    this.sessionManagement = false;
    this.setClientCookies  = false;

    // The repo root, one level up from this folder.
    variables.sRoot = getCanonicalPath( getDirectoryFromPath( getCurrentTemplatePath() ) & "../" );

    this.mappings[ "/testbox" ] = variables.sRoot & "testbox";
    this.mappings[ "/models" ]  = variables.sRoot & "models";
    this.mappings[ "/tests" ]   = variables.sRoot & "tests";

    public boolean function onRequestStart( required string targetPage ) {
        local.sIP = CGI.REMOTE_ADDR;
        if( !listFind( "127.0.0.1,::1,0:0:0:0:0:0:0:1", local.sIP ) ) {
            cfheader( statuscode = 404, statustext = "Not Found" );
            abort;
        }
        return true;
    }

}
