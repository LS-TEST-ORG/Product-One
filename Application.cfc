/*
    Application.cfc - an isolated application for compare.cfm.

    The comparison prints row data from the files it reads, so the page is gated twice:
      - who may call it: private/loopback addresses (allowPrivateNetworks) plus allowIPs;
        anyone else gets a 404
      - what it may read: only files under allowedRoots. Paths are canonicalised first, so
        ../ cannot climb out of a root

    Edit the settings below. Nothing else needs changing.
*/
component output=false {

    this.name = "ExportCompare_" & hash( getCurrentTemplatePath() );
    this.sessionManagement = false;
    this.setClientCookies  = false;
    this.requestTimeout    = createTimeSpan( 0, 0, 10, 0 ); // a large comparison takes minutes

    // A Lucee debug or documentation footer appended to the response would corrupt ?format=json.
    this.monitoring.showDebug  = false;
    this.monitoring.showDoc    = false;
    this.monitoring.showMetric = false;

    variables.settings = {
        // Directories the page may read. A relative entry is relative to this folder.
        "allowedRoots"         : [ "./data" ],
        "allowPrivateNetworks" : true,
        "allowIPs"             : [],
        // Where POI comes from when reader=poi - see readers/XlsxPoiReader.cfc. Examples:
        //   { "jars" : [ "/opt/lib/poi" ] }                                (a directory of jars)
        //   { "bundle" : "spreadsheet-cfml", "version" : "5.4.1.0",
        //     "bundlePath" : "/opt/lucee/spreadsheetLibrary/lib-osgi.jar" }  (Spreadsheet CFML's bundle;
        //                                                                    installed on first use)
        // Empty: the engine's own classpath.
        "poi"                  : {}
    };

    // Optional: let Lucee 6+ fetch POI from Maven instead (then leave "poi" empty above).
    // this.javaSettings = { maven = [ "org.apache.poi:poi-ooxml:5.4.1", "com.github.pjfanning:excel-streaming-reader:5.0.4" ] };


    public boolean function onRequestStart( required string targetPage ) {

        local.sIP = CGI.REMOTE_ADDR;
        local.bPrivate = reFind( "^10\.", local.sIP ) || reFind( "^172\.(1[6-9]|2[0-9]|3[01])\.", local.sIP )
                      || reFind( "^192\.168\.", local.sIP ) || local.sIP == "127.0.0.1" || local.sIP == "::1" || local.sIP == "0:0:0:0:0:0:0:1";
        if( !( variables.settings.allowPrivateNetworks && local.bPrivate ) && !arrayFind( variables.settings.allowIPs, local.sIP ) ) {
            cfheader( statuscode = 404, statustext = "Not Found" );
            abort;
        }

        // Only the page itself is served from this folder.
        if( listLast( arguments.targetPage, "/\" ) != "compare.cfm" ) {
            cfheader( statuscode = 404, statustext = "Not Found" );
            abort;
        }

        local.sHere = getDirectoryFromPath( getCurrentTemplatePath() );
        local.arrRoots = [];
        for( local.r in variables.settings.allowedRoots ) {
            local.sFull = ( left( local.r, 1 ) == "." ) ? local.sHere & local.r : local.r;
            arrayAppend( local.arrRoots, createObject( "java", "java.io.File" ).init( local.sFull ).getCanonicalPath() );
        }
        request.exportCompare = { "roots" = local.arrRoots, "poi" = variables.settings.poi };
        return true;
    }

}
