/*
    readers/XlsxJdkReader.cfc - reads .xlsx export parts WITHOUT Apache POI.

    An .xlsx file is a zip of XML documents. This reader uses only the JDK: java.util.zip.ZipFile to
    open it, and the StAX streaming parser (javax.xml.stream) to read it - one event at a time, so a
    large sheet is never held in memory as a document.

    What it reads (the first worksheet, or the one named by `sheet`):
      - shared strings (xl/sharedStrings.xml), including rich-text runs; phonetic runs are ignored
      - inline strings, formula string results, booleans (TRUE/FALSE), error values as stored
      - numbers AS STORED in the file (e.g. 12.5, 0.1, 1.0E-3). Not Excel's display format: two files
        written by the same writer compare correctly; for a CSV-vs-XLSX comparison use the engine's
        numericTolerant option, or the POI reader, which renders Excel's displayed text
      - dates: a number whose cell style is a date format becomes ISO text, yyyy-mm-dd or
        yyyy-mm-dd HH:nn:ss (dateMode="iso", the default), or stays the stored serial (dateMode="serial").
        The 1904 date system is honoured
      - gaps: a row that skips columns gets empty cells in the gaps; a skipped row is NOT invented

    Canonical record: cell values joined by chr(31), the same form CsvReader produces.

    Two ways through the sheet:
      fast (default, sheet XML up to inMemoryMB uncompressed, 300 MB): the XML is read into one
          string and reshaped by Java regex replacements - empty cells and formulas dropped, each
          value cell turned into delimited text - so CFML only splits native lists. Separators are
          ASCII 28-31, which XML 1.0 forbids in content, so they cannot collide with a value.
      streaming (larger sheets): StAX, one event at a time, constant memory, several times slower.
    Both give the same rows.

    XML security: DTDs and external entities are disabled on the StAX parser, so a crafted file
    cannot read local files or reach the network (XXE). The fast path never parses a DTD at all.
*/
component output=false {

    variables.US = chr(31);

    public any function init( string dateMode = "iso", string sheet = "", numeric inMemoryMB = 300 ) {
        variables.sDateMode   = arguments.dateMode;
        variables.sSheet      = arguments.sheet;
        variables.iInMemoryMB = arguments.inMemoryMB;

        variables.oXmlFactory = createObject( "java", "javax.xml.stream.XMLInputFactory" ).newInstance();
        variables.oXmlFactory.setProperty( "javax.xml.stream.supportDTD", javaCast( "boolean", false ) );
        variables.oXmlFactory.setProperty( "javax.xml.stream.isSupportingExternalEntities", javaCast( "boolean", false ) );
        variables.oXmlFactory.setProperty( "javax.xml.stream.isCoalescing", javaCast( "boolean", true ) );

        // StAX event codes
        variables.START = 1;
        variables.END   = 2;
        variables.TEXT  = 4;
        variables.CDATA = 12;

        // Built-in Excel number formats that are dates or times.
        variables.sBuiltinDateIds = "14,15,16,17,18,19,20,21,22,27,28,29,30,31,32,33,34,35,36,45,46,47,50,51,52,53,54,55,56,57,58";
        return this;
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
                // Excel omits trailing empty cells; pad to the header width so a trailing blank
                // compares equal to a CSV's empty last column.
                local.arrRow = local.arrRows[ local.i ];
                while( arrayLen( local.arrRow ) < arrayLen( local.ret.header ) ) { arrayAppend( local.arrRow, "" ); }
                arrayAppend( local.ret.records, arrayToList( local.arrRow, variables.US ) );
                local.iRows++;
            }
            arrayAppend( local.ret.parts, { "file" = local.sFile, "rows" = local.iRows } );
        }
        return local.ret;
    }


    // All rows of the chosen sheet, each an array of cell strings.
    public array function readSheet( required string file ) {

        local.oZip = createObject( "java", "java.util.zip.ZipFile" ).init( arguments.file );
        try {
            local.strBook   = readWorkbook( local.oZip );
            local.arrShared = readSharedStrings( local.oZip );
            local.arrDateXf = readDateStyles( local.oZip );
            local.oEntry = local.oZip.getEntry( local.strBook.sheetPath );
            if( isNull( local.oEntry ) ) { throw( type = "XlsxSheetMissing", message = "No worksheet at " & local.strBook.sheetPath ); }
            // Fast path holds the sheet's XML in memory; above the threshold, stream it instead.
            if( local.oEntry.getSize() >= 0 && local.oEntry.getSize() <= variables.iInMemoryMB * 1048576 ) {
                return readRowsFast( local.oZip, local.oEntry, local.arrShared, local.arrDateXf, local.strBook.date1904 );
            }
            return readRows( local.oZip, local.strBook.sheetPath, local.arrShared, local.arrDateXf, local.strBook.date1904 );
        }
        finally {
            local.oZip.close();
        }
    }


    // The sheet's zip path (via workbook.xml and its relationships) and the date system.
    private struct function readWorkbook( required any zip ) {

        local.ret = { "sheetPath" = "xl/worksheets/sheet1.xml", "date1904" = false };
        local.sRelId = "";

        local.r = openXml( arguments.zip, "xl/workbook.xml" );
        if( isNull( local.r ) ) { return local.ret; }
        try {
            while( local.r.hasNext() ) {
                if( local.r.next() != variables.START ) { continue; }
                local.sName = local.r.getLocalName();
                if( local.sName == "workbookPr" ) {
                    local.v = attr( local.r, "date1904" );
                    local.ret.date1904 = ( local.v == "1" || local.v == "true" );
                } else if( local.sName == "sheet" && !len( local.sRelId ) ) {
                    if( !len( variables.sSheet ) || attr( local.r, "name" ) == variables.sSheet ) {
                        local.sRelId = relId( local.r );
                    }
                }
            }
        } finally { local.r.close(); }

        if( !len( local.sRelId ) ) {
            if( len( variables.sSheet ) ) { throw( type = "XlsxSheetNotFound", message = "No sheet named '" & variables.sSheet & "'." ); }
            return local.ret;
        }

        local.r = openXml( arguments.zip, "xl/_rels/workbook.xml.rels" );
        if( isNull( local.r ) ) { return local.ret; }
        try {
            while( local.r.hasNext() ) {
                if( local.r.next() == variables.START && local.r.getLocalName() == "Relationship" && attr( local.r, "Id" ) == local.sRelId ) {
                    local.sTarget = attr( local.r, "Target" );
                    local.ret.sheetPath = left( local.sTarget, 1 ) == "/" ? mid( local.sTarget, 2, len( local.sTarget ) ) : "xl/" & local.sTarget;
                    break;
                }
            }
        } finally { local.r.close(); }
        return local.ret;
    }


    private array function readSharedStrings( required any zip ) {

        local.arr = [];
        local.r = openXml( arguments.zip, "xl/sharedStrings.xml" );
        if( isNull( local.r ) ) { return local.arr; }

        local.sCur = "";
        local.bInT = false;
        local.iSkip = 0;   // depth inside <rPh> (phonetic guide text, not part of the value)
        try {
            while( local.r.hasNext() ) {
                local.ev = local.r.next();
                if( local.ev == variables.START ) {
                    local.sName = local.r.getLocalName();
                    if( local.sName == "si" ) { local.sCur = ""; }
                    else if( local.sName == "rPh" ) { local.iSkip++; }
                    else if( local.sName == "t" && !local.iSkip ) { local.bInT = true; }
                } else if( local.ev == variables.END ) {
                    local.sName = local.r.getLocalName();
                    if( local.sName == "si" ) { arrayAppend( local.arr, local.sCur ); }
                    else if( local.sName == "rPh" ) { local.iSkip--; }
                    else if( local.sName == "t" ) { local.bInT = false; }
                } else if( local.bInT && ( local.ev == variables.TEXT || local.ev == variables.CDATA ) ) {
                    local.sCur &= local.r.getText();
                }
            }
        } finally { local.r.close(); }
        return local.arr;
    }


    // For each cellXfs entry (style index, 0-based), whether its number format is a date/time.
    private array function readDateStyles( required any zip ) {

        local.arr = [];
        local.r = openXml( arguments.zip, "xl/styles.xml" );
        if( isNull( local.r ) ) { return local.arr; }

        local.strCustom = {};
        local.bInXfs = false;
        try {
            while( local.r.hasNext() ) {
                local.ev = local.r.next();
                if( local.ev == variables.START ) {
                    local.sName = local.r.getLocalName();
                    if( local.sName == "numFmt" ) {
                        local.strCustom[ attr( local.r, "numFmtId" ) ] = attr( local.r, "formatCode" );
                    } else if( local.sName == "cellXfs" ) {
                        local.bInXfs = true;
                    } else if( local.sName == "xf" && local.bInXfs ) {
                        local.sId = attr( local.r, "numFmtId" );
                        arrayAppend( local.arr, structKeyExists( local.strCustom, local.sId )
                                                ? isDateFormat( local.strCustom[ local.sId ] )
                                                : listFind( variables.sBuiltinDateIds, val( local.sId ) ) > 0 );
                    }
                } else if( local.ev == variables.END && local.r.getLocalName() == "cellXfs" ) {
                    local.bInXfs = false;
                }
            }
        } finally { local.r.close(); }
        return local.arr;
    }


    // A custom format is a date if, outside quoted text, [..] blocks and escapes, it uses d, y, h or s
    // (m alone is ambiguous between month and minute, and appears in plain number formats too).
    private boolean function isDateFormat( required string fmt ) {
        local.s = reReplace( arguments.fmt, '"[^"]*"', "", "all" );
        local.s = reReplace( local.s, "\[[^\]]*\]", "", "all" );
        local.s = reReplace( local.s, "\\.", "", "all" );
        return reFindNoCase( "[dyhs]", local.s ) > 0;
    }


    /*
        Fast path. Each step is one Java-side replaceAll over the whole sheetData, so the per-cell
        work left for CFML is splitting native lists:
            <c r="AB12" s="3" t="s"><v>17</v></c>   ->   RS AB GS s GS 3 GS 17
            </row>                                  ->   FS
        then entities are decoded. Rows are FS(28)-separated, cells RS(30), fields GS(29).
    */
    private array function readRowsFast( required any zip, required any entry, required array shared, required array dateXf, required boolean date1904 ) {

        local.oIn = arguments.zip.getInputStream( arguments.entry );
        try {
            local.sXml = createObject( "java", "java.lang.String" ).init( local.oIn.readAllBytes(), "UTF-8" );
        } finally { local.oIn.close(); }

        local.iFrom = local.sXml.indexOf( "<sheetData" );
        local.iTo   = local.sXml.lastIndexOf( "</sheetData>" );
        if( local.iFrom < 0 || local.iTo < 0 ) { return []; }   // <sheetData/> - an empty sheet
        local.s = local.sXml.substring( local.sXml.indexOf( ">", local.iFrom ) + 1, local.iTo );
        local.sXml = "";

        local.P  = createObject( "java", "java.util.regex.Pattern" );
        local.FS = chr(28); local.GS = chr(29); local.RS = chr(30);

        local.arrSteps = [
            [ '<c\b[^>]*/>',                                       '' ],              // empty cells
            [ '<f\b[^>]*/>|<f\b[^>]*>.*?</f>',                     '' ],              // formulas (the cached value stays)
            [ '<rPh\b.*?</rPh>|<rPr\b.*?</rPr>|<rPr\b[^>]*/>',     '' ],              // phonetic runs, run formatting
            [ '<c(?=[^>]*\br="([A-Za-z]+)[0-9]*")?(?=[^>]*\bt="([A-Za-z]+)")?(?=[^>]*\bs="([0-9]+)")?[^>]*>',
                                                                   local.RS & '$1' & local.GS & '$2' & local.GS & '$3' & local.GS ],
            [ '</row>',                                            local.FS ],
            [ '</?(?:row|v|is|r|t|c)\b[^>]*>',                     '' ]               // every remaining tag
        ];
        for( local.arrStep in local.arrSteps ) {
            local.s = local.P.compile( local.arrStep[ 1 ], javaCast( "int", 32 ) ).matcher( local.s ).replaceAll( local.arrStep[ 2 ] ); // 32 = DOTALL
        }
        if( find( "&", local.s ) ) { local.s = decodeEntities( local.s ); }

        local.strCols = {};
        local.iShared = arrayLen( arguments.shared );
        local.iDateXf = arrayLen( arguments.dateXf );
        local.bIso    = variables.sDateMode == "iso";
        local.arrRows = [];

        for( local.sRow in listToArray( local.s, local.FS, true ) ) {
            local.arrRow = [];
            for( local.sCell in listToArray( local.sRow, local.RS, false ) ) {
                local.arrF = listToArray( local.sCell, local.GS, true );
                if( arrayLen( local.arrF ) < 3 ) { continue; } // whitespace between tags
                local.sLetters = local.arrF[ 1 ];
                local.sType    = local.arrF[ 2 ];
                local.iStyle   = len( local.arrF[ 3 ] ) ? val( local.arrF[ 3 ] ) : -1;
                local.sVal     = arrayLen( local.arrF ) >= 4 ? local.arrF[ 4 ] : "";

                if( len( local.sLetters ) ) {
                    if( !structKeyExists( local.strCols, local.sLetters ) ) { local.strCols[ local.sLetters ] = colIndex( local.sLetters ); }
                    local.iCol = local.strCols[ local.sLetters ];
                } else {
                    local.iCol = arrayLen( local.arrRow ) + 1;
                }
                while( arrayLen( local.arrRow ) < local.iCol - 1 ) { arrayAppend( local.arrRow, "" ); }

                if( local.sType == "s" ) {
                    local.i = val( local.sVal ) + 1;
                    local.arrRow[ local.iCol ] = local.i <= local.iShared ? arguments.shared[ local.i ] : "";
                } else if( local.sType == "" && ( !local.bIso || local.iStyle < 0 || local.iStyle >= local.iDateXf || !arguments.dateXf[ local.iStyle + 1 ] ) ) {
                    local.arrRow[ local.iCol ] = local.sVal;
                } else {
                    local.arrRow[ local.iCol ] = cellText( local.sType, local.sVal, local.iStyle, arguments.shared, arguments.dateXf, arguments.date1904 );
                }
            }
            arrayAppend( local.arrRows, local.arrRow );
        }

        while( arrayLen( local.arrRows ) && !len( arrayToList( local.arrRows[ arrayLen( local.arrRows ) ], "" ) ) ) {
            arrayDeleteAt( local.arrRows, arrayLen( local.arrRows ) );
        }
        return local.arrRows;
    }


    // XML character references and the five predefined entities. &amp; last, so "&amp;lt;" stays "&lt;".
    private string function decodeEntities( required string s ) {
        local.r = arguments.s;
        if( find( "&##", local.r ) ) {
            local.m = createObject( "java", "java.util.regex.Pattern" ).compile( "&##(x?)([0-9A-Fa-f]+);" ).matcher( local.r );
            local.sb = createObject( "java", "java.lang.StringBuffer" ).init();
            while( local.m.find() ) {
                local.iCode = len( local.m.group( javaCast( "int", 1 ) ) ) ? inputBaseN( local.m.group( javaCast( "int", 2 ) ), 16 ) : val( local.m.group( javaCast( "int", 2 ) ) );
                local.m.appendReplacement( local.sb, createObject( "java", "java.util.regex.Matcher" ).quoteReplacement( chr( local.iCode ) ) );
            }
            local.m.appendTail( local.sb );
            local.r = local.sb.toString();
        }
        local.r = replace( local.r, "&lt;", "<", "all" );
        local.r = replace( local.r, "&gt;", ">", "all" );
        local.r = replace( local.r, "&quot;", '"', "all" );
        local.r = replace( local.r, "&apos;", "'", "all" );
        return replace( local.r, "&amp;", "&", "all" );
    }


    /*
        The hot loop: a 25k-row, 150-column export is ~4M cells, so everything per cell is inlined -
        a CFML function call costs more than the XML work it would wrap. Column letters are cached
        (an export has only as many distinct letters as columns), and the common cell types (shared
        string, plain number) are resolved here; only dates and the rare types go through cellText().
    */
    private array function readRows( required any zip, required string sheetPath, required array shared, required array dateXf, required boolean date1904 ) {

        local.arrRows = [];
        local.r = openXml( arguments.zip, arguments.sheetPath );
        if( isNull( local.r ) ) { throw( type = "XlsxSheetMissing", message = "No worksheet at " & arguments.sheetPath ); }

        local.strCols   = {};
        local.arrShared = arguments.shared;
        local.iShared   = arrayLen( local.arrShared );
        local.arrDateXf = arguments.dateXf;
        local.iDateXf   = arrayLen( local.arrDateXf );
        local.bIso      = variables.sDateMode == "iso";

        local.arrRow = [];
        local.sType = ""; local.iCol = 0; local.iStyle = -1;
        local.sVal = ""; local.bCapture = false; local.bInInline = false;

        try {
            while( local.r.hasNext() ) {
                local.ev = local.r.next();

                if( local.ev == 1 ) {
                    local.sName = local.r.getLocalName();
                    if( local.sName == "c" ) {
                        local.sType = local.r.getAttributeValue( javaCast( "null", "" ), "t" );
                        if( isNull( local.sType ) ) { local.sType = ""; }
                        local.sRef = local.r.getAttributeValue( javaCast( "null", "" ), "r" );
                        if( isNull( local.sRef ) ) {
                            local.iCol = arrayLen( local.arrRow ) + 1;
                        } else {
                            local.sLetters = spanExcluding( local.sRef, "0123456789" );
                            if( !structKeyExists( local.strCols, local.sLetters ) ) { local.strCols[ local.sLetters ] = colIndex( local.sLetters ); }
                            local.iCol = local.strCols[ local.sLetters ];
                        }
                        local.sStyle = local.r.getAttributeValue( javaCast( "null", "" ), "s" );
                        local.iStyle = isNull( local.sStyle ) ? -1 : val( local.sStyle );
                        local.sVal = "";
                    } else if( local.sName == "v" ) {
                        local.bCapture = true;
                    } else if( local.sName == "row" ) {
                        local.arrRow = [];
                    } else if( local.sName == "is" ) {
                        local.bInInline = true;
                    } else if( local.sName == "t" && local.bInInline ) {
                        local.bCapture = true;
                    }
                }
                else if( local.ev == 4 || local.ev == 12 ) {
                    if( local.bCapture ) { local.sVal &= local.r.getText(); }
                }
                else if( local.ev == 2 ) {
                    local.sName = local.r.getLocalName();
                    if( local.sName == "c" ) {
                        while( arrayLen( local.arrRow ) < local.iCol - 1 ) { arrayAppend( local.arrRow, "" ); }
                        if( local.sType == "s" ) {
                            local.i = val( local.sVal ) + 1;
                            local.arrRow[ local.iCol ] = local.i <= local.iShared ? local.arrShared[ local.i ] : "";
                        } else if( local.sType == "" && ( !local.bIso || local.iStyle < 0 || local.iStyle >= local.iDateXf || !local.arrDateXf[ local.iStyle + 1 ] ) ) {
                            local.arrRow[ local.iCol ] = local.sVal;
                        } else {
                            local.arrRow[ local.iCol ] = cellText( local.sType, local.sVal, local.iStyle, local.arrShared, local.arrDateXf, arguments.date1904 );
                        }
                    } else if( local.sName == "v" || local.sName == "t" ) {
                        local.bCapture = false;
                    } else if( local.sName == "row" ) {
                        arrayAppend( local.arrRows, local.arrRow );
                    } else if( local.sName == "is" ) {
                        local.bInInline = false;
                    }
                }
            }
        } finally { local.r.close(); }

        // Excel may leave formatted-but-empty rows at the end of a sheet.
        while( arrayLen( local.arrRows ) && !len( arrayToList( local.arrRows[ arrayLen( local.arrRows ) ], "" ) ) ) {
            arrayDeleteAt( local.arrRows, arrayLen( local.arrRows ) );
        }
        return local.arrRows;
    }


    private string function cellText( required string type, required string raw, required numeric style,
                                      required array shared, required array dateXf, required boolean date1904 ) {
        switch( arguments.type ) {
            case "s":
                local.i = val( arguments.raw ) + 1;
                return local.i <= arrayLen( arguments.shared ) ? arguments.shared[ local.i ] : "";
            case "inlineStr": case "str": case "e":
                return arguments.raw;
            case "b":
                return arguments.raw == "1" ? "TRUE" : ( arguments.raw == "0" ? "FALSE" : arguments.raw );
            case "d":
                return arguments.raw; // ISO 8601 date cell, already text
        }
        // a number
        if( variables.sDateMode == "iso" && len( arguments.raw ) && isNumeric( arguments.raw )
            && arguments.style >= 0 && arguments.style < arrayLen( arguments.dateXf ) && arguments.dateXf[ arguments.style + 1 ] ) {
            return serialToIso( arguments.raw, arguments.date1904 );
        }
        return arguments.raw;
    }


    private string function serialToIso( required string serial, required boolean date1904 ) {
        local.n = val( arguments.serial );
        local.dEpoch = arguments.date1904 ? createDateTime( 1904, 1, 1, 0, 0, 0 ) : createDateTime( 1899, 12, 30, 0, 0, 0 );
        local.iDays = int( local.n );
        local.iSecs = round( ( local.n - local.iDays ) * 86400 );
        local.d = dateAdd( "s", local.iSecs, dateAdd( "d", local.iDays, local.dEpoch ) );
        return local.iSecs == 0 ? dateFormat( local.d, "yyyy-mm-dd" ) : dateFormat( local.d, "yyyy-mm-dd" ) & " " & timeFormat( local.d, "HH:mm:ss" );
    }


    // "AB" (or "AB12") -> 28
    private numeric function colIndex( required string ref ) {
        local.sLetters = uCase( reReplace( arguments.ref, "[0-9]", "", "all" ) );
        local.n = 0;
        for( local.i = 1; local.i <= len( local.sLetters ); local.i++ ) {
            local.n = local.n * 26 + ( asc( mid( local.sLetters, local.i, 1 ) ) - 64 );
        }
        return local.n;
    }


    // A StAX reader over one zip entry, or null when the entry is absent.
    private any function openXml( required any zip, required string path ) {
        local.oEntry = arguments.zip.getEntry( arguments.path );
        if( isNull( local.oEntry ) ) { return; }
        return variables.oXmlFactory.createXMLStreamReader( arguments.zip.getInputStream( local.oEntry ), "UTF-8" );
    }


    private string function attr( required any reader, required string name ) {
        local.v = arguments.reader.getAttributeValue( javaCast( "null", "" ), arguments.name );
        return isNull( local.v ) ? "" : local.v;
    }


    // The r:id attribute of a <sheet>, whatever prefix the relationships namespace uses.
    private string function relId( required any reader ) {
        for( local.i = 0; local.i < arguments.reader.getAttributeCount(); local.i++ ) {
            if( arguments.reader.getAttributeLocalName( javaCast( "int", local.i ) ) == "id" ) {
                return arguments.reader.getAttributeValue( javaCast( "int", local.i ) );
            }
        }
        return "";
    }

}
