/*
    ExportCompare.cfc - is a candidate export run identical to a baseline run?

    Built for proving that a refactored export still produces the same data (a performance rewrite,
    a library swap), where the files themselves always differ - a timestamp in the filename, a part
    boundary that moved, a column of run times - so a plain byte compare says "different" for runs
    that are the same, and cannot say what differs when they are not.

    compareRuns( baseline, candidate [, options] ) - each side is ONE export run: a file, a list of part
    files, or a directory (every .csv / .xlsx / .xls in it, name order, excluding `exclude`).

    The answer, strongest first:

        BYTE-IDENTICAL  every part file is byte-for-byte equal (same part count, same order)
        DATA-IDENTICAL  same header, same rows in the same order; only the file bytes differ
                        (part boundaries, quoting, line endings, CSV vs XLSX, ...)
        EQUIVALENT      the same data, but only after allowing for the differences you declared
                        harmless: row order, value order inside multi-value cells, masked columns,
                        number formatting. Each is counted, so you can see what was allowed
        DIFFERENT       real differences: rows missing or added, cell values changed, columns changed
        UNKNOWN         a side could not be read

    How rows are matched:
      key = "AccountCode" (or a list for a composite key)
            rows are paired by key, and every differing cell is reported with both values.
            Never pair by position: export finalisation is often unordered.
      no key -> sorted multiset: rows are matched by their whole content, so duplicates and
            near-duplicate rows (seeded clones) still compare exactly. Differences are reported as
            rows only in one side; give a key for cell-level detail.

    Options (all optional):
      key             column name(s) identifying a row
      mask            column names to ignore (per-run values: timestamps, run ids)
      multiValue      delimiter of multi-value cells, compared as SETS (default "|"; "" to disable)
      numericTolerant numbers equal as numbers compare equal ("12.50" = "12.5"). Default false: it
                      would also equate "007" with "7", hiding a lost leading zero. Turn it on for
                      CSV-vs-XLSX comparisons, where number rendering legitimately differs
      trim            trim cell values before comparing                                    default false
      reader          auto | csv | jdk | poi   (auto: by extension; .xlsx/.xls use jdk unless poi is set)
      poi             { jars = [...] } | { bundle = "...", version = "..." } - see readers/XlsxPoiReader
      csvDelimiter    default ","          encoding   default "utf-8"
      sheet           sheet name for spreadsheets (default: the first)
      dateMode        iso | serial, for the jdk reader (default iso)
      poiValues       stored | display, for the poi reader (default stored - see readers/XlsxPoiReader)
      headerRows      header rows at the top of EVERY part (default 1)
      exclude         regex; files whose name matches are skipped (default "PerfTimings")
      sampleLimit     differences listed per category (default 20)

    Returns a struct; render() turns it into the text report. Verdict line first, always:
        EXPORT-COMPARE: <VERDICT>  rows=<a>/<b> ...
*/
component output=false {

    variables.US = chr(31);

    public any function init() {
        return this;
    }


    public struct function compareRuns( required any baseline, required any candidate, struct options = {} ) {

        local.o = defaults();
        structAppend( local.o, arguments.options, true );
        local.o.key  = isArray( local.o.key )  ? local.o.key  : listToArray( local.o.key );
        local.o.mask = isArray( local.o.mask ) ? local.o.mask : listToArray( local.o.mask );

        local.t0 = getTickCount();
        local.res = {
            "verdict"    = "UNKNOWN",
            "options"    = local.o,
            "baseline"   = {},
            "candidate"  = {},
            "bytes"      = {},
            "header"     = {},
            "rows"       = {},
            "matching"   = "",
            "allowed"    = { "rowOrder" = "same", "columnOrder" = false, "multiValueOrder" = 0, "masked" = 0, "numericFormat" = 0, "trimmed" = 0 },
            "diffColumns"= {},
            "samples"    = { "changed" = [], "onlyBaseline" = [], "onlyCandidate" = [] },
            "warnings"   = [],
            "ms"         = 0
        };

        try {
            local.arrA = collect( arguments.baseline, local.o );
            local.arrB = collect( arguments.candidate, local.o );
            local.res.baseline[ "files" ]  = local.arrA;
            local.res.candidate[ "files" ] = local.arrB;
            if( !arrayLen( local.arrA ) || !arrayLen( local.arrB ) ) {
                arrayAppend( local.res.warnings, "no export files found on " & ( !arrayLen( local.arrA ) ? "the baseline" : "the candidate" ) & " side" );
                return finish( local.res, local.t0 );
            }

            // -- 1. bytes ---------------------------------------------------------------------
            local.res[ "bytes" ] = byteCheck( local.arrA, local.arrB );
            if( local.res.bytes.identical ) {
                local.res[ "verdict" ] = "BYTE-IDENTICAL";
                return finish( local.res, local.t0 );
            }

            // -- 2. read ----------------------------------------------------------------------
            local.A = readSide( local.arrA, local.o );
            local.B = readSide( local.arrB, local.o );
            local.res.baseline[ "reader" ]  = local.A.reader;
            local.res.candidate[ "reader" ] = local.B.reader;
            for( local.w in local.A.warnings ) { arrayAppend( local.res.warnings, "baseline: " & local.w ); }
            for( local.w in local.B.warnings ) { arrayAppend( local.res.warnings, "candidate: " & local.w ); }
            local.res.baseline[ "parts" ]  = local.A.parts;
            local.res.candidate[ "parts" ] = local.B.parts;

            // -- 3. header --------------------------------------------------------------------
            local.res[ "header" ] = headerCheck( local.A.header, local.B.header );
            if( !local.res.header.identical ) {
                // Compare on the shared columns, in baseline order. Changed columns are themselves a difference.
                local.B.records = project( local.B.records, local.B.header, local.res.header.common );
                local.A.records = project( local.A.records, local.A.header, local.res.header.common );
                local.arrCols = local.res.header.common;
            } else {
                local.arrCols = local.A.header;
            }

            // -- 4. rows ----------------------------------------------------------------------
            local.nA = arrayLen( local.A.records );
            local.nB = arrayLen( local.B.records );
            local.res[ "rows" ] = { "baseline" = local.nA, "candidate" = local.nB, "sameOrder" = 0 };
            for( local.i = 1; local.i <= min( local.nA, local.nB ); local.i++ ) {
                if( compare( local.A.records[ local.i ], local.B.records[ local.i ] ) == 0 ) { local.res.rows.sameOrder++; }
            }

            if( local.res.header.identical && local.nA == local.nB && local.res.rows.sameOrder == local.nA ) {
                local.res[ "verdict" ] = "DATA-IDENTICAL";
                return finish( local.res, local.t0 );
            }

            // -- 5. match ---------------------------------------------------------------------
            local.strCtx = context( local.arrCols, local.o );
            if( arrayLen( local.o.key ) && arrayLen( local.strCtx.keyIdx ) == arrayLen( local.o.key ) ) {
                local.bKeyed = matchByKey( local.A.records, local.B.records, local.strCtx, local.o, local.res );
                if( !local.bKeyed ) { matchAsMultiset( local.A.records, local.B.records, local.strCtx, local.o, local.res ); }
            } else {
                if( arrayLen( local.o.key ) ) {
                    arrayAppend( local.res.warnings, "key column(s) " & arrayToList( local.o.key ) & " not in the header - matched as a multiset instead" );
                }
                matchAsMultiset( local.A.records, local.B.records, local.strCtx, local.o, local.res );
            }

            // -- 6. verdict -------------------------------------------------------------------
            local.bReal = arrayLen( local.res.samples.changed ) || local.res.rows.onlyBaseline || local.res.rows.onlyCandidate
                       || !local.res.header.sameColumns || local.res.rows.changed;
            local.res[ "verdict" ] = local.bReal ? "DIFFERENT" : "EQUIVALENT";
            if( !local.res.header.identical && local.res.header.reordered ) { local.res.allowed[ "columnOrder" ] = true; }
        }
        catch( any e ) {
            local.res[ "verdict" ] = "UNKNOWN";
            arrayAppend( local.res.warnings, "could not complete: " & e.message & ( len( e.detail ) ? " - " & e.detail : "" ) );
        }
        return finish( local.res, local.t0 );
    }


    // Read one side without comparing - what the engine would see. Used by DumpTask.
    public struct function readOnly( required any side, struct options = {} ) {
        local.o = defaults();
        structAppend( local.o, arguments.options, true );
        return readSide( collect( arguments.side, local.o ), local.o );
    }


    public struct function defaults() {
        return {
            "key" = [], "mask" = [], "multiValue" = "|", "numericTolerant" = false, "trim" = false,
            "reader" = "auto", "poi" = {}, "csvDelimiter" = ",", "encoding" = "utf-8",
            "sheet" = "", "dateMode" = "iso", "poiValues" = "stored", "headerRows" = 1, "exclude" = "PerfTimings", "sampleLimit" = 20
        };
    }


    // ---------------------------------------------------------------------------------------
    // files
    // ---------------------------------------------------------------------------------------

    private array function collect( required any side, required struct o ) {
        local.arrIn  = isArray( arguments.side ) ? arguments.side : [ arguments.side ];
        local.arrOut = [];
        for( local.sPath in local.arrIn ) {
            if( directoryExists( local.sPath ) ) {
                local.arrFiles = directoryList( local.sPath, false, "path", "*.csv|*.xlsx|*.xls" );
                arraySort( local.arrFiles, "textnocase" );
                for( local.f in local.arrFiles ) {
                    if( len( arguments.o.exclude ) && reFindNoCase( arguments.o.exclude, getFileFromPath( local.f ) ) ) { continue; }
                    arrayAppend( local.arrOut, local.f );
                }
            } else if( fileExists( local.sPath ) ) {
                arrayAppend( local.arrOut, local.sPath );
            } else {
                throw( type = "ExportCompareNotFound", message = "Not found: " & local.sPath );
            }
        }
        return local.arrOut;
    }


    private struct function byteCheck( required array a, required array b ) {
        local.ret = { "identical" = false, "parts" = [] };
        local.bAll = arrayLen( arguments.a ) == arrayLen( arguments.b );
        for( local.i = 1; local.i <= max( arrayLen( arguments.a ), arrayLen( arguments.b ) ); local.i++ ) {
            local.hA = local.i <= arrayLen( arguments.a ) ? hash( fileReadBinary( arguments.a[ local.i ] ), "SHA-256" ) : "";
            local.hB = local.i <= arrayLen( arguments.b ) ? hash( fileReadBinary( arguments.b[ local.i ] ), "SHA-256" ) : "";
            arrayAppend( local.ret.parts, { "part" = local.i, "same" = ( len( local.hA ) && local.hA == local.hB ) } );
            if( local.hA != local.hB ) { local.bAll = false; }
        }
        local.ret[ "identical" ] = local.bAll;
        return local.ret;
    }


    private struct function readSide( required array files, required struct o ) {
        local.sExt = lCase( listLast( arguments.files[ 1 ], "." ) );
        for( local.f in arguments.files ) {
            if( lCase( listLast( local.f, "." ) ) != local.sExt ) {
                throw( type = "ExportCompareMixed", message = "One side mixes file types (." & local.sExt & " and ." & listLast( local.f, "." ) & ")." );
            }
        }

        local.sReader = arguments.o.reader;
        if( local.sReader == "auto" ) {
            local.sReader = local.sExt == "csv" ? "csv" : ( structIsEmpty( arguments.o.poi ) && local.sExt == "xlsx" ? "jdk" : "poi" );
        }
        if( local.sExt == "csv" ) { local.sReader = "csv"; }
        if( local.sExt == "xls" ) { local.sReader = "poi"; } // the binary format has no XML to stream

        switch( local.sReader ) {
            case "csv":
                local.oReader = new readers.CsvReader( arguments.o.csvDelimiter, arguments.o.encoding );
                local.sLabel = "csv";
                break;
            case "jdk":
                local.oReader = new readers.XlsxJdkReader( arguments.o.dateMode, arguments.o.sheet );
                local.sLabel = "xlsx via JDK (no POI)";
                break;
            default:
                local.oReader = new readers.XlsxPoiReader( arguments.o.poi, arguments.o.sheet, arguments.o.poiValues );
                local.sLabel = "xlsx via " & local.oReader.mode();
        }
        local.ret = local.oReader.readParts( arguments.files, arguments.o.headerRows );
        local.ret[ "reader" ] = local.sLabel;

        // Line breaks inside values: CRLF and CR become LF, on every reader. A CSV cannot carry the
        // difference reliably (CsvReader already reads LF), so neither side keeps it.
        local.CR = chr(13);
        for( local.i = 1; local.i <= arrayLen( local.ret.records ); local.i++ ) {
            if( find( local.CR, local.ret.records[ local.i ] ) ) {
                local.ret.records[ local.i ] = replace( replace( local.ret.records[ local.i ], local.CR & chr(10), chr(10), "all" ), local.CR, chr(10), "all" );
            }
        }
        return local.ret;
    }


    // ---------------------------------------------------------------------------------------
    // header
    // ---------------------------------------------------------------------------------------

    private struct function headerCheck( required array a, required array b ) {
        local.ret = { "identical" = ( arrayToList( arguments.a, variables.US ) == arrayToList( arguments.b, variables.US ) ),
                      "sameColumns" = true, "onlyBaseline" = [], "onlyCandidate" = [], "reordered" = false, "common" = [] };
        if( local.ret.identical ) { local.ret.common = arguments.a; return local.ret; }

        for( local.c in arguments.a ) {
            if( arrayFind( arguments.b, local.c ) ) { arrayAppend( local.ret.common, local.c ); }
            else { arrayAppend( local.ret.onlyBaseline, local.c ); }
        }
        for( local.c in arguments.b ) {
            if( !arrayFind( arguments.a, local.c ) ) { arrayAppend( local.ret.onlyCandidate, local.c ); }
        }
        local.ret[ "sameColumns" ] = !arrayLen( local.ret.onlyBaseline ) && !arrayLen( local.ret.onlyCandidate );
        local.ret[ "reordered" ] = local.ret.sameColumns;
        return local.ret;
    }


    // Re-express records over a column list, by name. The first column of a given name wins.
    private array function project( required array records, required array header, required array cols ) {
        local.arrIdx = [];
        for( local.c in arguments.cols ) { arrayAppend( local.arrIdx, arrayFind( arguments.header, local.c ) ); }
        local.arrOut = [];
        for( local.r in arguments.records ) {
            local.arrCells = listToArray( local.r, variables.US, true );
            local.arrNew = [];
            for( local.i in local.arrIdx ) { arrayAppend( local.arrNew, local.i <= arrayLen( local.arrCells ) ? local.arrCells[ local.i ] : "" ); }
            arrayAppend( local.arrOut, arrayToList( local.arrNew, variables.US ) );
        }
        return local.arrOut;
    }


    // ---------------------------------------------------------------------------------------
    // matching
    // ---------------------------------------------------------------------------------------

    private struct function context( required array cols, required struct o ) {
        local.ret = { "cols" = arguments.cols, "keyIdx" = [], "maskIdx" = {}, "numericKeys" = arguments.o.numericTolerant };
        for( local.k in arguments.o.key ) {
            local.i = arrayFindNoCase( arguments.cols, trim( local.k ) );
            if( local.i ) { arrayAppend( local.ret.keyIdx, local.i ); }
        }
        for( local.m in arguments.o.mask ) {
            local.i = arrayFindNoCase( arguments.cols, trim( local.m ) );
            if( local.i ) { local.ret.maskIdx[ local.i ] = true; }
        }
        return local.ret;
    }


    // Returns false (caller falls back to multiset) when a key is not unique on either side.
    private boolean function matchByKey( required array a, required array b, required struct ctx, required struct o, required struct res ) {

        local.mapA = indexByKey( arguments.a, arguments.ctx );
        local.mapB = indexByKey( arguments.b, arguments.ctx );
        if( local.mapA.dupes || local.mapB.dupes ) {
            arrayAppend( arguments.res.warnings, "key " & arrayToList( arguments.o.key ) & " is not unique ("
                & local.mapA.dupes & " duplicate(s) in the baseline, " & local.mapB.dupes & " in the candidate) - matched as a multiset instead" );
            return false;
        }

        arguments.res[ "matching" ] = "by key: " & arrayToList( arguments.o.key );

        // Row order is the order of the keys, not of whole rows: a row that differs only in an
        // allowed way has not moved.
        local.arrOrderA = []; local.arrOrderB = [];
        local.it = local.mapA.map.keySet().iterator();
        while( local.it.hasNext() ) { local.k = local.it.next(); if( local.mapB.map.containsKey( local.k ) ) { arrayAppend( local.arrOrderA, local.k ); } }
        local.it = local.mapB.map.keySet().iterator();
        while( local.it.hasNext() ) { local.k = local.it.next(); if( local.mapA.map.containsKey( local.k ) ) { arrayAppend( local.arrOrderB, local.k ); } }
        arguments.res.allowed[ "rowOrder" ] = "same";
        for( local.i = 1; local.i <= arrayLen( local.arrOrderA ); local.i++ ) {
            if( compare( local.arrOrderA[ local.i ], local.arrOrderB[ local.i ] ) != 0 ) { arguments.res.allowed[ "rowOrder" ] = "differs"; break; }
        }
        arguments.res.rows[ "onlyBaseline" ] = 0;
        arguments.res.rows[ "onlyCandidate" ] = 0;
        arguments.res.rows[ "changed" ] = 0;
        arguments.res.rows[ "equivalent" ] = 0;

        local.itA = local.mapA.map.entrySet().iterator();
        while( local.itA.hasNext() ) {
            local.e = local.itA.next();
            local.iA = local.e.getValue();
            local.iB = local.mapB.map.get( local.e.getKey() );
            if( isNull( local.iB ) ) {
                arguments.res.rows.onlyBaseline++;
                addSample( arguments.res.samples.onlyBaseline, { "key" = displayKey( local.e.getKey() ), "row" = rowStruct( arguments.a[ local.iA ], arguments.ctx ) }, arguments.o );
                continue;
            }
            local.sA = arguments.a[ local.iA ];
            local.sB = arguments.b[ local.iB ];
            if( compare( local.sA, local.sB ) == 0 ) { continue; }

            local.strCells = compareCells( local.sA, local.sB, arguments.ctx, arguments.o, arguments.res );
            if( arrayLen( local.strCells.real ) ) {
                arguments.res.rows.changed++;
                addSample( arguments.res.samples.changed, { "key" = displayKey( local.e.getKey() ), "cells" = local.strCells.real }, arguments.o );
            } else {
                arguments.res.rows.equivalent++;
            }
        }

        local.itB = local.mapB.map.entrySet().iterator();
        while( local.itB.hasNext() ) {
            local.e = local.itB.next();
            if( isNull( local.mapA.map.get( local.e.getKey() ) ) ) {
                arguments.res.rows.onlyCandidate++;
                addSample( arguments.res.samples.onlyCandidate, { "key" = displayKey( local.e.getKey() ), "row" = rowStruct( arguments.b[ local.e.getValue() ], arguments.ctx ) }, arguments.o );
            }
        }
        return true;
    }


    // key -> record index, in a case-SENSITIVE Java map (a CFML struct would merge "ab" and "AB").
    private struct function indexByKey( required array records, required struct ctx ) {
        local.map = createObject( "java", "java.util.LinkedHashMap" ).init();
        local.iDupes = 0;
        for( local.i = 1; local.i <= arrayLen( arguments.records ); local.i++ ) {
            local.arrCells = listToArray( arguments.records[ local.i ], variables.US, true );
            local.arrKey = [];
            for( local.k in arguments.ctx.keyIdx ) {
                local.v = local.k <= arrayLen( local.arrCells ) ? local.arrCells[ local.k ] : "";
                // Under numericTolerant a key of 14341.0 (spreadsheet) must find 14341 (CSV).
                if( arguments.ctx.numericKeys && isPlainNumber( local.v ) ) {
                    local.v = createObject( "java", "java.math.BigDecimal" ).init( trim( local.v ) ).stripTrailingZeros().toPlainString();
                }
                arrayAppend( local.arrKey, local.v );
            }
            local.sKey = arrayToList( local.arrKey, variables.US );
            if( local.map.containsKey( local.sKey ) ) { local.iDupes++; continue; }
            local.map.put( local.sKey, javaCast( "int", local.i ) );
        }
        return { "map" = local.map, "dupes" = local.iDupes };
    }


    /*
        Sorted-multiset matching: count each whole row on both sides (case-sensitive), cancel the
        pairs, then normalise only the leftovers (mask, multi-value order, numbers, trim) and cancel
        again. What survives the second pass is a real difference.
    */
    private void function matchAsMultiset( required array a, required array b, required struct ctx, required struct o, required struct res ) {

        arguments.res[ "matching" ] = "as a multiset (whole-row content)";
        local.mapCount = createObject( "java", "java.util.HashMap" ).init();
        for( local.r in arguments.a ) { bump( local.mapCount, local.r, 1 ); }
        for( local.r in arguments.b ) { bump( local.mapCount, local.r, -1 ); }

        local.arrLeftA = []; local.arrLeftB = [];
        local.it = local.mapCount.entrySet().iterator();
        while( local.it.hasNext() ) {
            local.e = local.it.next();
            local.n = local.e.getValue();
            for( local.j = 1; local.j <= abs( local.n ); local.j++ ) {
                if( local.n > 0 ) { arrayAppend( local.arrLeftA, local.e.getKey() ); }
                else { arrayAppend( local.arrLeftB, local.e.getKey() ); }
            }
        }

        // second pass over the leftovers only
        local.mapNorm = createObject( "java", "java.util.HashMap" ).init();
        local.strRaw = { "A" = createObject( "java", "java.util.HashMap" ).init(), "B" = createObject( "java", "java.util.HashMap" ).init() };
        for( local.r in local.arrLeftA ) {
            local.sN = normalise( local.r, arguments.ctx, arguments.o );
            bump( local.mapNorm, local.sN, 1 );
            local.strRaw.A.put( local.sN, local.r );
        }
        for( local.r in local.arrLeftB ) {
            local.sN = normalise( local.r, arguments.ctx, arguments.o );
            bump( local.mapNorm, local.sN, -1 );
            local.strRaw.B.put( local.sN, local.r );
        }

        arguments.res.rows[ "onlyBaseline" ] = 0;
        arguments.res.rows[ "onlyCandidate" ] = 0;
        arguments.res.rows[ "changed" ] = 0;
        arguments.res.rows[ "equivalent" ] = 0;
        local.it = local.mapNorm.entrySet().iterator();
        while( local.it.hasNext() ) {
            local.e = local.it.next();
            local.n = local.e.getValue();
            if( local.n > 0 ) {
                arguments.res.rows.onlyBaseline += local.n;
                addSample( arguments.res.samples.onlyBaseline, { "row" = rowStruct( local.strRaw.A.get( local.e.getKey() ), arguments.ctx ), "count" = local.n }, arguments.o );
            } else if( local.n < 0 ) {
                arguments.res.rows.onlyCandidate += -local.n;
                addSample( arguments.res.samples.onlyCandidate, { "row" = rowStruct( local.strRaw.B.get( local.e.getKey() ), arguments.ctx ), "count" = -local.n }, arguments.o );
            }
        }
        // Leftover baseline rows that found a partner only after normalising: equal under the allowances.
        arguments.res.rows[ "equivalent" ] = arrayLen( local.arrLeftA ) - arguments.res.rows.onlyBaseline;

        // Without a key, order is only knowable when every row matched as-is.
        if( !arrayLen( local.arrLeftA ) && !arrayLen( local.arrLeftB ) ) {
            arguments.res.allowed[ "rowOrder" ] = arguments.res.rows.sameOrder == arrayLen( arguments.a ) ? "same" : "differs";
        } else {
            arguments.res.allowed[ "rowOrder" ] = "not determined without a key";
        }
    }


    private void function bump( required any map, required string k, required numeric delta ) {
        local.v = arguments.map.get( arguments.k );
        arguments.map.put( arguments.k, javaCast( "int", ( isNull( local.v ) ? 0 : local.v ) + arguments.delta ) );
    }


    // ---------------------------------------------------------------------------------------
    // cells
    // ---------------------------------------------------------------------------------------

    // Classify every differing cell of a keyed pair. Allowed differences are tallied; the rest returned.
    private struct function compareCells( required string a, required string b, required struct ctx, required struct o, required struct res ) {
        local.arrA = listToArray( arguments.a, variables.US, true );
        local.arrB = listToArray( arguments.b, variables.US, true );
        local.ret = { "real" = [] };
        local.n = max( arrayLen( local.arrA ), arrayLen( local.arrB ) );

        for( local.i = 1; local.i <= local.n; local.i++ ) {
            local.vA = local.i <= arrayLen( local.arrA ) ? local.arrA[ local.i ] : "";
            local.vB = local.i <= arrayLen( local.arrB ) ? local.arrB[ local.i ] : "";
            if( compare( local.vA, local.vB ) == 0 ) { continue; }

            local.sCol = local.i <= arrayLen( arguments.ctx.cols ) ? arguments.ctx.cols[ local.i ] : "(column " & local.i & ")";
            local.sWhy = allowance( local.vA, local.vB, structKeyExists( arguments.ctx.maskIdx, local.i ), arguments.o );

            if( len( local.sWhy ) ) {
                arguments.res.allowed[ local.sWhy ]++;
                continue;
            }
            if( !structKeyExists( arguments.res.diffColumns, local.sCol ) ) { arguments.res.diffColumns[ local.sCol ] = 0; }
            arguments.res.diffColumns[ local.sCol ]++;
            arrayAppend( local.ret.real, { "column" = local.sCol, "baseline" = local.vA, "candidate" = local.vB } );
        }
        return local.ret;
    }


    // "" when the difference is real, else which allowance covers it.
    private string function allowance( required string a, required string b, required boolean masked, required struct o ) {
        if( arguments.masked ) { return "masked"; }
        local.vA = arguments.a; local.vB = arguments.b;
        if( arguments.o.trim ) {
            local.vA = trim( local.vA ); local.vB = trim( local.vB );
            if( compare( local.vA, local.vB ) == 0 ) { return "trimmed"; }
        }
        if( len( arguments.o.multiValue ) && ( find( arguments.o.multiValue, local.vA ) || find( arguments.o.multiValue, local.vB ) ) ) {
            if( compare( sortedSet( local.vA, arguments.o.multiValue ), sortedSet( local.vB, arguments.o.multiValue ) ) == 0 ) { return "multiValueOrder"; }
        }
        if( arguments.o.numericTolerant && numericEqual( local.vA, local.vB ) ) { return "numericFormat"; }
        return "";
    }


    // The row in a form where every allowance is already applied, for the multiset second pass.
    private string function normalise( required string r, required struct ctx, required struct o ) {
        local.arr = listToArray( arguments.r, variables.US, true );
        for( local.i = 1; local.i <= arrayLen( local.arr ); local.i++ ) {
            local.v = local.arr[ local.i ];
            if( structKeyExists( arguments.ctx.maskIdx, local.i ) ) { local.arr[ local.i ] = ""; continue; }
            if( arguments.o.trim ) { local.v = trim( local.v ); }
            if( len( arguments.o.multiValue ) && find( arguments.o.multiValue, local.v ) ) { local.v = sortedSet( local.v, arguments.o.multiValue ); }
            if( arguments.o.numericTolerant && isPlainNumber( local.v ) ) {
                local.v = createObject( "java", "java.math.BigDecimal" ).init( trim( local.v ) ).stripTrailingZeros().toPlainString();
            }
            local.arr[ local.i ] = local.v;
        }
        return arrayToList( local.arr, variables.US );
    }


    private string function sortedSet( required string v, required string delim ) {
        local.arr = listToArray( arguments.v, arguments.delim, true, true );
        arraySort( local.arr, "text" );
        return arrayToList( local.arr, arguments.delim );
    }


    private boolean function numericEqual( required string a, required string b ) {
        if( !isPlainNumber( arguments.a ) || !isPlainNumber( arguments.b ) ) { return false; }
        return createObject( "java", "java.math.BigDecimal" ).init( trim( arguments.a ) )
                   .compareTo( createObject( "java", "java.math.BigDecimal" ).init( trim( arguments.b ) ) ) == 0;
    }


    // Strictly a decimal number - isNumeric() also accepts things like "1e" variants and dates on some engines.
    private boolean function isPlainNumber( required string v ) {
        return reFind( "^\s*[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?\s*$", arguments.v ) > 0;
    }


    // ---------------------------------------------------------------------------------------
    // report
    // ---------------------------------------------------------------------------------------

    private void function addSample( required array arr, required struct item, required struct o ) {
        if( arrayLen( arguments.arr ) < arguments.o.sampleLimit ) { arrayAppend( arguments.arr, arguments.item ); }
    }

    private string function displayKey( required string k ) {
        return replace( arguments.k, variables.US, " | ", "all" );
    }

    private struct function rowStruct( required string r, required struct ctx ) {
        local.arr = listToArray( arguments.r, variables.US, true );
        local.ret = structNew( "ordered" );
        for( local.i = 1; local.i <= min( arrayLen( local.arr ), 8 ); local.i++ ) {
            local.ret[ local.i <= arrayLen( arguments.ctx.cols ) ? arguments.ctx.cols[ local.i ] : "col" & local.i ] = left( local.arr[ local.i ], 60 );
        }
        return local.ret;
    }

    private struct function finish( required struct res, required numeric t0 ) {
        arguments.res[ "ms" ] = getTickCount() - arguments.t0;
        arguments.res[ "line" ] = verdictLine( arguments.res );
        return arguments.res;
    }


    public string function verdictLine( required struct res ) {
        local.s = "EXPORT-COMPARE: " & arguments.res.verdict;
        if( structKeyExists( arguments.res.rows, "baseline" ) ) {
            local.s &= "  rows=" & arguments.res.rows.baseline & "/" & arguments.res.rows.candidate;
            if( structKeyExists( arguments.res.rows, "changed" ) ) {
                local.s &= " changed=" & arguments.res.rows.changed & " onlyBaseline=" & arguments.res.rows.onlyBaseline
                         & " onlyCandidate=" & arguments.res.rows.onlyCandidate;
            }
        }
        local.s &= "  ms=" & arguments.res.ms;
        return local.s;
    }


    // A value as one readable line: line breaks and tabs shown as \n \r \t, long values cut.
    private string function visible( required string v ) {
        local.s = replace( replace( replace( arguments.v, chr(13), "\r", "all" ), chr(10), "\n", "all" ), chr(9), "\t", "all" );
        return len( local.s ) > 200 ? left( local.s, 200 ) & "... (" & len( arguments.v ) & " chars)" : local.s;
    }


    // Plain-text report: the verdict line first, then what was compared and what differed.
    public string function render( required struct res ) {
        local.nl = chr(10);
        local.o = arguments.res;
        local.s = local.o.line & local.nl & repeatString( "=", 78 ) & local.nl;

        for( local.sSide in [ "baseline", "candidate" ] ) {
            local.strSide = local.o[ local.sSide ];
            local.arrFiles = structKeyExists( local.strSide, "files" ) ? local.strSide.files : [];
            local.s &= left( local.sSide & "          ", 10 ) & ": " & arrayLen( local.arrFiles ) & " file(s)"
                     & ( structKeyExists( local.strSide, "reader" ) ? "  [" & local.strSide.reader & "]" : "" ) & local.nl;
            for( local.f in local.arrFiles ) { local.s &= "              " & local.f & local.nl; }
        }

        if( structKeyExists( local.o.bytes, "parts" ) ) {
            local.iSame = 0;
            for( local.p in local.o.bytes.parts ) { if( local.p.same ) { local.iSame++; } }
            local.s &= "bytes     : " & local.iSame & " of " & arrayLen( local.o.bytes.parts ) & " part file(s) byte-identical" & local.nl;
        }

        if( structKeyExists( local.o.header, "identical" ) ) {
            if( local.o.header.identical ) {
                local.s &= "header    : identical (" & arrayLen( local.o.header.common ) & " columns)" & local.nl;
            } else {
                local.s &= "header    : DIFFERS - compared on " & arrayLen( local.o.header.common ) & " shared columns" & local.nl;
                if( arrayLen( local.o.header.onlyBaseline ) )  { local.s &= "            only in baseline : " & arrayToList( local.o.header.onlyBaseline, ", " ) & local.nl; }
                if( arrayLen( local.o.header.onlyCandidate ) ) { local.s &= "            only in candidate: " & arrayToList( local.o.header.onlyCandidate, ", " ) & local.nl; }
                if( local.o.header.reordered ) { local.s &= "            same columns, different order" & local.nl; }
            }
        }

        if( structKeyExists( local.o.rows, "baseline" ) ) {
            local.s &= "rows      : baseline " & local.o.rows.baseline & ", candidate " & local.o.rows.candidate
                     & ", " & local.o.rows.sameOrder & " identical at the same position" & local.nl;
        }
        if( len( local.o.matching ) ) {
            local.s &= "matching  : " & local.o.matching & local.nl;
            local.s &= "            changed " & local.o.rows.changed & ", only in baseline " & local.o.rows.onlyBaseline
                     & ", only in candidate " & local.o.rows.onlyCandidate & ", equal after allowances " & local.o.rows.equivalent & local.nl;
            local.s &= "allowed   : row order " & local.o.allowed.rowOrder
                     & ", column order " & ( local.o.allowed.columnOrder ? "differs" : "same" ) & local.nl;
            if( left( local.o.matching, 6 ) == "by key" ) {
                local.s &= "            cells allowed - multi-value order " & local.o.allowed.multiValueOrder
                         & ", masked " & local.o.allowed.masked
                         & ", number format " & local.o.allowed.numericFormat
                         & ", whitespace " & local.o.allowed.trimmed & local.nl;
            } else {
                local.s &= "            (per-cell allowance counts need a key; give key= to see them)" & local.nl;
            }
        }

        if( !structIsEmpty( local.o.diffColumns ) ) {
            local.s &= local.nl & "COLUMNS WITH REAL DIFFERENCES" & local.nl;
            for( local.c in local.o.diffColumns ) { local.s &= "  " & local.c & " : " & local.o.diffColumns[ local.c ] & " row(s)" & local.nl; }
        }
        if( arrayLen( local.o.samples.changed ) ) {
            local.s &= local.nl & "CHANGED ROWS (first " & arrayLen( local.o.samples.changed ) & ")" & local.nl;
            for( local.r in local.o.samples.changed ) {
                local.s &= "  key " & local.r.key & local.nl;
                for( local.c in local.r.cells ) {
                    local.s &= "      " & local.c.column & local.nl
                             & "        baseline : " & visible( local.c.baseline ) & local.nl
                             & "        candidate: " & visible( local.c.candidate ) & local.nl;
                }
            }
        }
        for( local.sSide in [ "onlyBaseline", "onlyCandidate" ] ) {
            if( arrayLen( local.o.samples[ local.sSide ] ) ) {
                local.s &= local.nl & ( local.sSide == "onlyBaseline" ? "ROWS ONLY IN THE BASELINE" : "ROWS ONLY IN THE CANDIDATE" )
                         & " (first " & arrayLen( local.o.samples[ local.sSide ] ) & ", first 8 columns)" & local.nl;
                for( local.r in local.o.samples[ local.sSide ] ) {
                    local.s &= "  " & ( structKeyExists( local.r, "key" ) ? "key " & local.r.key & "  " : "" )
                             & ( structKeyExists( local.r, "count" ) && local.r.count > 1 ? "x" & local.r.count & "  " : "" )
                             & serializeJSON( local.r.row ) & local.nl;
                }
            }
        }
        if( arrayLen( local.o.warnings ) ) {
            local.s &= local.nl & "WARNINGS" & local.nl;
            for( local.w in local.o.warnings ) { local.s &= "  " & local.w & local.nl; }
        }
        return local.s;
    }

}
