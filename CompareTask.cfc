/*
    CompareTask.cfc - run the comparison from the command line with CommandBox. No server needed.

        box task run CompareTask.cfc :baseline=<path> :candidate=<path> [:key=AccountCode] [:mask=LastTouch] ...

    Every ExportCompare option is accepted as a :name=value argument (lists comma-separated):
        :key  :mask  :multiValue  :numericTolerant  :trim  :reader=auto|csv|jdk|poi
        :poiJars=<jar or directory,...>   :poiBundle=<symbolic name>  :poiVersion=<version>
        :csvDelimiter  :encoding  :sheet  :dateMode=iso|serial  :headerRows  :exclude  :sampleLimit
        :json=true    print the result as JSON instead of the text report

    Exit code: 0 byte-identical / data-identical / equivalent, 1 different, 2 unknown (could not read).
*/
component {

    function run( required string baseline, required string candidate ) {

        local.o = {};
        for( local.k in [ "key", "mask", "multiValue", "reader", "csvDelimiter", "encoding", "sheet", "dateMode", "exclude" ] ) {
            if( structKeyExists( arguments, local.k ) ) { local.o[ local.k ] = arguments[ local.k ]; }
        }
        for( local.k in [ "numericTolerant", "trim" ] ) {
            if( structKeyExists( arguments, local.k ) ) { local.o[ local.k ] = isBoolean( arguments[ local.k ] ) && arguments[ local.k ]; }
        }
        for( local.k in [ "headerRows", "sampleLimit" ] ) {
            if( structKeyExists( arguments, local.k ) ) { local.o[ local.k ] = val( arguments[ local.k ] ); }
        }
        if( structKeyExists( arguments, "poiJars" ) ) {
            local.o.poi = { "jars" = listToArray( arguments.poiJars ) };
        } else if( structKeyExists( arguments, "poiBundle" ) ) {
            local.o.poi = { "bundle" = arguments.poiBundle, "version" = structKeyExists( arguments, "poiVersion" ) ? arguments.poiVersion : "" };
        }

        local.oCompare = createObject( "component", "ExportCompare" ).init();
        local.res = local.oCompare.compareRuns( resolvePath( arguments.baseline ), resolvePath( arguments.candidate ), local.o );

        if( structKeyExists( arguments, "json" ) && isBoolean( arguments.json ) && arguments.json ) {
            print.line( serializeJSON( local.res ) );
        } else {
            print.line( local.oCompare.render( local.res ) );
        }

        switch( local.res.verdict ) {
            case "DIFFERENT": setExitCode( 1 ); break;
            case "UNKNOWN":   setExitCode( 2 ); break;
        }
    }

}
