/*
    readers/XlsxPoiReader.cfc - reads .xlsx (and .xls) export parts WITH Apache POI.

    Cell values (values = "stored", the default) are what the file HOLDS, as XlsxJdkReader reads them:
      text as is; numbers in POI's shortest exact form (NumberToTextConverter: 36.67, 4615, 1E-3);
      date-formatted numbers as ISO text (yyyy-mm-dd, or yyyy-mm-dd HH:mm:ss with a time part);
      booleans TRUE/FALSE; formulas as their cached result; errors as their Excel code (#N/A).
    The JDK reader returns a number's stored text verbatim, so it may say 4615.0 where this one says
    4615 - compare like with like, or set numericTolerant.

    values = "display" returns what Excel SHOWS instead (POI's DataFormatter, the cell's number format
    applied). Avoid it for equality checks: a format of "0" shows 36.67 and 37.4 both as 37, so two
    different stored values can compare equal.

    Where POI comes from - `poi` setting, tried in this order:
      { jars   = [ "/path/poi-5.4.1.jar", ... ] }      jar files (or one directory of jars) passed to
                                                        createObject("java", class, jars)
      { bundle = "spreadsheet-cfml", version = "5.4.1.0" [, bundlePath = "/path/lib-osgi.jar"] }
                                                        a Lucee OSGi bundle - e.g. the one the Spreadsheet
                                                        CFML library ships as lib-osgi.jar. With bundlePath,
                                                        the bundle is installed first if Lucee has not loaded
                                                        it yet (Lucee only, as the library itself does)
      (nothing)                                         the engine's own classpath (jars in lucee lib,
                                                        or this.javaSettings in Application.cfc)

    Large files: when the excel-streaming-reader library (com.github.pjfanning.xlsx.StreamingReader)
    is reachable the same way, rows are streamed with a small row cache instead of loading the whole
    workbook. Otherwise POI's XSSFWorkbook loads the file in full, which needs heap of several times
    the unzipped sheet size.

    Canonical record: cell values joined by chr(31), the same form the other readers produce.
*/
component output=false {

    variables.US = chr(31);

    public any function init( struct poi = {}, string sheet = "", string values = "stored" ) {
        variables.strPoi  = arguments.poi;
        variables.sSheet  = arguments.sheet;
        variables.bStored = arguments.values != "display";

        if( structKeyExists( variables.strPoi, "jars" ) ) {
            variables.arrJars = expandJars( variables.strPoi.jars );
        } else if( structKeyExists( variables.strPoi, "bundle" ) && structKeyExists( variables.strPoi, "bundlePath" ) ) {
            ensureBundle( variables.strPoi.bundle, structKeyExists( variables.strPoi, "version" ) ? variables.strPoi.version : "", variables.strPoi.bundlePath );
        }
        // Fail early, with a useful message, if POI cannot be reached at all.
        variables.oFormatter = javaClass( "org.apache.poi.ss.usermodel.DataFormatter" ).init();
        variables.oDateUtil  = javaClass( "org.apache.poi.ss.usermodel.DateUtil" );
        variables.oNumText   = javaClass( "org.apache.poi.ss.util.NumberToTextConverter" );
        variables.sStreaming = "";
        try {
            variables.oStreaming = javaClass( "com.github.pjfanning.xlsx.StreamingReader" );
            variables.sStreaming = "excel-streaming-reader";
        } catch( any e ) {}
        return this;
    }


    // "excel-streaming-reader" or "" - reported by the engine so a reader can tell how a file was read.
    public string function mode() {
        return len( variables.sStreaming ) ? "poi+streaming" : "poi (whole workbook in memory)";
    }


    // Same contract as CsvReader.readParts.
    public struct function readParts( required array files, numeric headerRows = 1 ) {

        local.ret = { "header" = [], "records" = [], "parts" = [], "warnings" = [] };

        for( local.sFile in arguments.files ) {
            local.arrRows = readSheet( local.sFile );
            local.iRows = 0;
            for( local.i = 1; local.i <= arrayLen( local.arrRows ); local.i++ ) {
                if( local.i <= arguments.headerRows ) {
                    if( !arrayLen( local.ret.header ) ) {
                        local.ret.header = local.arrRows[ local.i ];
                    } else if( arrayToList( local.arrRows[ local.i ], variables.US ) != arrayToList( local.ret.header, variables.US ) ) {
                        arrayAppend( local.ret.warnings, getFileFromPath( local.sFile ) & ": header differs from the first part's" );
                    }
                    continue;
                }
                local.arrRow = local.arrRows[ local.i ];
                while( arrayLen( local.arrRow ) < arrayLen( local.ret.header ) ) { arrayAppend( local.arrRow, "" ); }
                arrayAppend( local.ret.records, arrayToList( local.arrRow, variables.US ) );
                local.iRows++;
            }
            arrayAppend( local.ret.parts, { "file" = local.sFile, "rows" = local.iRows } );
        }
        return local.ret;
    }


    public array function readSheet( required string file ) {

        local.oIn = createObject( "java", "java.io.FileInputStream" ).init( arguments.file );
        local.oBook = "";
        try {
            if( len( variables.sStreaming ) && lCase( listLast( arguments.file, "." ) ) == "xlsx" ) {
                local.oBuilder = variables.oStreaming.builder();
                local.oBuilder = local.oBuilder.rowCacheSize( javaCast( "int", 200 ) );
                local.oBuilder = local.oBuilder.bufferSize( javaCast( "int", 8192 ) );
                local.oBook = local.oBuilder.open( local.oIn );
            } else {
                local.oBook = javaClass( "org.apache.poi.ss.usermodel.WorkbookFactory" ).create( local.oIn );
            }

            local.oSheet = len( variables.sSheet ) ? local.oBook.getSheet( variables.sSheet ) : local.oBook.getSheetAt( javaCast( "int", 0 ) );
            if( isNull( local.oSheet ) ) { throw( type = "XlsxSheetNotFound", message = "No sheet named '" & variables.sSheet & "'." ); }

            local.arrRows = [];
            local.itRows = local.oSheet.rowIterator();
            while( local.itRows.hasNext() ) {
                local.oRow = local.itRows.next();
                local.arrRow = [];
                local.itCells = local.oRow.cellIterator();
                while( local.itCells.hasNext() ) {
                    local.oCell = local.itCells.next();
                    local.iCol = local.oCell.getColumnIndex() + 1;
                    while( arrayLen( local.arrRow ) < local.iCol - 1 ) { arrayAppend( local.arrRow, "" ); }
                    local.arrRow[ local.iCol ] = variables.bStored ? storedValue( local.oCell ) : variables.oFormatter.formatCellValue( local.oCell );
                }
                arrayAppend( local.arrRows, local.arrRow );
            }
            while( arrayLen( local.arrRows ) && !len( arrayToList( local.arrRows[ arrayLen( local.arrRows ) ], "" ) ) ) {
                arrayDeleteAt( local.arrRows, arrayLen( local.arrRows ) );
            }
            return local.arrRows;
        }
        finally {
            closeQuietly( local.oBook );
            local.oIn.close();
        }
    }


    private string function storedValue( required any cell ) {
        local.sType = arguments.cell.getCellType().name();
        if( local.sType == "FORMULA" ) { local.sType = arguments.cell.getCachedFormulaResultType().name(); }
        switch( local.sType ) {
            case "STRING":
                return arguments.cell.getStringCellValue();
            case "NUMERIC":
                if( variables.oDateUtil.isCellDateFormatted( arguments.cell ) ) {
                    local.dt = arguments.cell.getLocalDateTimeCellValue();
                    local.sDate = local.dt.toLocalDate().toString();
                    if( local.dt.getHour() + local.dt.getMinute() + local.dt.getSecond() == 0 ) { return local.sDate; }
                    return local.sDate & " " & numberFormat( local.dt.getHour(), "00" ) & ":" & numberFormat( local.dt.getMinute(), "00" ) & ":" & numberFormat( local.dt.getSecond(), "00" );
                }
                return variables.oNumText.toText( arguments.cell.getNumericCellValue() );
            case "BOOLEAN":
                return arguments.cell.getBooleanCellValue() ? "TRUE" : "FALSE";
            case "ERROR":
                return variables.oFormatter.formatCellValue( arguments.cell );
        }
        return ""; // BLANK
    }


    // Kept out of the finally above: a try/catch nested in a finally crashes Lucee 5's compiler.
    private void function closeQuietly( required any obj ) {
        if( !isObject( arguments.obj ) ) { return; }
        try { arguments.obj.close(); } catch( any e ) {}
    }


    private any function javaClass( required string className ) {
        if( structKeyExists( variables, "arrJars" ) ) {
            return createObject( "java", arguments.className, variables.arrJars );
        }
        if( structKeyExists( variables.strPoi, "bundle" ) ) {
            return createObject( "java", arguments.className, variables.strPoi.bundle,
                                 structKeyExists( variables.strPoi, "version" ) ? variables.strPoi.version : "" );
        }
        try {
            return createObject( "java", arguments.className );
        } catch( any e ) {
            throw( type = "PoiNotAvailable",
                   message = "Apache POI is not reachable (" & arguments.className & ").",
                   detail  = "Put the POI jars on the classpath, or pass poi = { jars = [...] } or poi = { bundle = ""..."", version = ""..."" }, or use reader=jdk, which needs no POI." );
        }
    }


    // Install an OSGi bundle into Lucee unless that name and version are already loaded.
    private void function ensureBundle( required string name, required string version, required string path ) {
        local.oOsgi = createObject( "java", "lucee.runtime.osgi.OSGiUtil" );
        local.oLoaded = local.oOsgi.getBundleLoaded( arguments.name, local.oOsgi.toVersion( arguments.version ), javaCast( "null", "" ) );
        if( !isNull( local.oLoaded ) ) { return; }
        if( !fileExists( arguments.path ) ) {
            throw( type = "PoiNotAvailable", message = "OSGi bundle file not found: " & arguments.path );
        }
        local.oEngine = createObject( "java", "lucee.loader.engine.CFMLEngineFactory" ).getInstance();
        local.oResource = local.oEngine.getResourceUtil().toResourceExisting( getPageContext(), javaCast( "string", arguments.path ) );
        local.oOsgi.installBundle( local.oEngine.getBundleContext(), local.oResource, javaCast( "boolean", true ) );
    }


    // Accept jar paths or directories (every *.jar inside).
    private array function expandJars( required any jars ) {
        local.arrIn  = isArray( arguments.jars ) ? arguments.jars : listToArray( arguments.jars );
        local.arrOut = [];
        for( local.sPath in local.arrIn ) {
            if( directoryExists( local.sPath ) ) {
                for( local.sJar in directoryList( local.sPath, false, "path", "*.jar" ) ) { arrayAppend( local.arrOut, local.sJar ); }
            } else {
                arrayAppend( local.arrOut, local.sPath );
            }
        }
        return local.arrOut;
    }

}
