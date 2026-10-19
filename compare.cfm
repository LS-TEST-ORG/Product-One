<cfprocessingdirective suppressWhitespace="false"><cfsetting showDebugOutput="false" enablecfoutputonly="true">
<cfscript>
/*
    compare.cfm - compare two export runs in the browser or with curl.

        compare.cfm?baseline=<path>&candidate=<path>[&key=AccountCode][&mask=LastTouch][&format=json]

    Paths are relative to the first allowedRoot in Application.cfc, or absolute inside any of them.
    Each side is a file, or a directory holding one export run's part files.

    Every ExportCompare option is a URL parameter: key, mask, multiValue, numericTolerant, trim,
    reader (auto|csv|jdk|poi), csvDelimiter, encoding, sheet, dateMode, poiValues, headerRows,
    exclude, sampleLimit. POI's location comes from Application.cfc, never from the URL.

    The first line of the text report is the verdict:
        EXPORT-COMPARE: BYTE-IDENTICAL | DATA-IDENTICAL | EQUIVALENT | DIFFERENT | UNKNOWN
    Read that line, not the HTTP status (always 200 unless the request itself is refused).
*/
cfcontent( type = "text/plain; charset=utf-8", reset = true );

function resolveInRoots( required string p ) {
    var sIn = trim( arguments.p );
    if( !len( sIn ) ) { throw( type = "Input", message = "baseline and candidate are both required." ); }
    var bAbs = left( sIn, 1 ) == "/" || left( sIn, 1 ) == "\" || reFind( "^[A-Za-z]:[\\/]", sIn );
    var sFull = bAbs ? sIn : request.exportCompare.roots[ 1 ] & "/" & sIn;
    var sCanon = createObject( "java", "java.io.File" ).init( sFull ).getCanonicalPath();
    for( var sRoot in request.exportCompare.roots ) {
        if( sCanon == sRoot || left( sCanon, len( sRoot ) + 1 ) == sRoot & createObject( "java", "java.io.File" ).separator ) {
            return sCanon;
        }
    }
    throw( type = "Input", message = "'" & sIn & "' is outside the allowed roots." );
}

try {
    variables.o = {};
    for( variables.k in [ "key", "mask", "multiValue", "reader", "csvDelimiter", "encoding", "sheet", "dateMode", "poiValues", "exclude" ] ) {
        if( structKeyExists( url, variables.k ) ) { variables.o[ variables.k ] = url[ variables.k ]; }
    }
    for( variables.k in [ "numericTolerant", "trim" ] ) {
        if( structKeyExists( url, variables.k ) ) { variables.o[ variables.k ] = isBoolean( url[ variables.k ] ) && url[ variables.k ]; }
    }
    for( variables.k in [ "headerRows", "sampleLimit" ] ) {
        if( structKeyExists( url, variables.k ) && isNumeric( url[ variables.k ] ) ) { variables.o[ variables.k ] = int( url[ variables.k ] ); }
    }
    variables.o.poi = request.exportCompare.poi;

    variables.oCompare = new ExportCompare();
    variables.res = variables.oCompare.compareRuns(
        resolveInRoots( structKeyExists( url, "baseline" ) ? url.baseline : "" ),
        resolveInRoots( structKeyExists( url, "candidate" ) ? url.candidate : "" ),
        variables.o
    );

    if( structKeyExists( url, "format" ) && url.format == "json" ) {
        cfcontent( type = "application/json; charset=utf-8", reset = true );
        writeOutput( serializeJSON( variables.res ) );
    } else {
        writeOutput( variables.oCompare.render( variables.res ) );
    }
}
catch( Input e ) {
    cfheader( statuscode = 400 );
    writeOutput( "EXPORT-COMPARE: UNKNOWN  " & e.message & chr(10) );
}
abort;
</cfscript>
</cfprocessingdirective>
