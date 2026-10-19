/*
    DumpTask.cfc - write the rows a reader sees to a tab-separated file, to inspect or diff by hand.

        box task run taskFile=DumpTask.cfc :source=<file or directory> :out=<file.tsv> [:reader=jdk|poi|csv] [:poiJars=...]

    Header first, then every data row of every part, exactly as the comparison engine sees them
    (backslash, tab, CR and LF inside values are written as \\ \t \r \n).
*/
component {

    function run( required string source, required string out, string reader = "auto" ) {

        local.o = createObject( "component", "ExportCompare" ).init().defaults();
        local.o.reader = arguments.reader;
        if( structKeyExists( arguments, "poiJars" ) ) { local.o.poi = { "jars" = listToArray( arguments.poiJars ) }; }
        if( structKeyExists( arguments, "dateMode" ) ) { local.o.dateMode = arguments.dateMode; }

        local.oCompare = createObject( "component", "ExportCompare" ).init();
        local.side = local.oCompare.readOnly( resolvePath( arguments.source ), local.o );

        local.oOut = createObject( "java", "java.io.PrintWriter" ).init( resolvePath( arguments.out ), "UTF-8" );
        try {
            local.oOut.print( tsv( arrayToList( local.side.header, chr(31) ) ) & chr(10) );
            for( local.r in local.side.records ) { local.oOut.print( tsv( local.r ) & chr(10) ); }
        } finally { local.oOut.close(); }

        print.line( arrayLen( local.side.records ) & " rows, " & arrayLen( local.side.header ) & " columns [" & local.side.reader & "] -> " & resolvePath( arguments.out ) );
    }

    private string function tsv( required string canonical ) {
        local.s = replace( arguments.canonical, "\", "\\", "all" );
        local.s = replace( local.s, chr(9), "\t", "all" );
        local.s = replace( local.s, chr(13), "\r", "all" );
        local.s = replace( local.s, chr(10), "\n", "all" );
        return replace( local.s, chr(31), chr(9), "all" );
    }

}
