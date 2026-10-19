/*
    readers/CsvReader.cfc - reads CSV export parts into canonical records. No libraries needed.

    Canonical record: the row's cell values joined with chr(31) (ASCII unit separator), so a CSV
    row and an XLSX row holding the same values produce the same string and compare directly.

    Handles: quoted and unquoted fields, doubled quotes inside quoted fields, line breaks inside
    quoted fields, an optional UTF-8 BOM, CRLF or LF line endings, a header row on every part.

    Speed: a 25k-row, 150-column export is ~4M cells, too many to walk character by character in
    CFML. Each record therefore takes the cheapest path that is still exact:
      1. fully quoted, no escaped quote inside   -> one replace() of  ","  by chr(31)
      2. no quote character at all               -> one replace() of the delimiter by chr(31)
      3. anything else                           -> a Java regex tokenizer, field by field
    Paths 1 and 2 cover almost every row a typical export writer produces.

    Line breaks INSIDE a field are normalised to LF on both sides, so a CRLF-vs-LF difference inside
    a cell value is not reported.
*/
component output=false {

    variables.US = chr(31);

    public any function init( string delimiter = ",", string encoding = "utf-8" ) {
        variables.sDelim    = arguments.delimiter;
        variables.sEncoding = arguments.encoding;
        variables.oLineSplit = createObject( "java", "java.util.regex.Pattern" ).compile( "\r?\n" );
        // One field: a quoted value (doubled quotes allowed, line breaks allowed) or a bare value,
        // followed by the delimiter or the end of the record.
        local.sD = createObject( "java", "java.util.regex.Pattern" ).quote( variables.sDelim );
        variables.oField = createObject( "java", "java.util.regex.Pattern" ).compile(
            '\G(?:"((?:[^"]|"")*)"|([^"' & reReplace( variables.sDelim, "([\\\]\[\^-])", "\\\1", "all" ) & ']*))(' & local.sD & '|$)',
            javaCast( "int", 32 ) // Pattern.DOTALL
        );
        return this;
    }


    /*
        Read every part of one export run, in the order given.
        Returns { header = [names], records = [canonical], parts = [ { file, rows } ], warnings = [] }.
        The first row of each part is its header; every part's header must match the first one.
    */
    public struct function readParts( required array files, numeric headerRows = 1 ) {

        local.ret = { "header" = [], "records" = [], "parts" = [], "warnings" = [] };

        for( local.sFile in arguments.files ) {

            local.arrRecords = splitRecords( fileRead( local.sFile, variables.sEncoding ) );
            local.iRows = 0;

            for( local.i = 1; local.i <= arrayLen( local.arrRecords ); local.i++ ) {
                local.sCanon = canonical( local.arrRecords[ local.i ] );
                if( local.i <= arguments.headerRows ) {
                    if( !arrayLen( local.ret.header ) ) {
                        local.ret.header = listToArray( local.sCanon, variables.US, true );
                    } else if( local.sCanon != arrayToList( local.ret.header, variables.US ) ) {
                        arrayAppend( local.ret.warnings, getFileFromPath( local.sFile ) & ": header differs from the first part's" );
                    }
                    continue;
                }
                arrayAppend( local.ret.records, local.sCanon );
                local.iRows++;
            }
            arrayAppend( local.ret.parts, { "file" = local.sFile, "rows" = local.iRows } );
        }
        return local.ret;
    }


    /*
        Split text into raw records: lines, re-joined while a quoted field is still open (an odd
        number of quote characters so far). A trailing empty line is dropped.
    */
    public array function splitRecords( required string text ) {

        local.s = arguments.text;
        if( len( local.s ) && asc( left( local.s, 1 ) ) == 65279 ) { local.s = mid( local.s, 2, len( local.s ) ); }

        local.arrLines = variables.oLineSplit.split( local.s, javaCast( "int", -1 ) );
        local.arrOut   = [];
        local.sOpen    = "";
        local.iQuotes  = 0;
        local.bOpen    = false;

        for( local.sLine in local.arrLines ) {
            local.iQ = len( local.sLine ) - len( replace( local.sLine, '"', "", "all" ) );
            if( local.bOpen ) {
                local.sOpen &= chr(10) & local.sLine;
                local.iQuotes += local.iQ;
            } else {
                local.sOpen = local.sLine;
                local.iQuotes = local.iQ;
            }
            local.bOpen = ( local.iQuotes mod 2 ) == 1;
            if( !local.bOpen ) { arrayAppend( local.arrOut, local.sOpen ); }
        }
        if( local.bOpen ) { arrayAppend( local.arrOut, local.sOpen ); } // unterminated quote: keep what there is

        while( arrayLen( local.arrOut ) && !len( local.arrOut[ arrayLen( local.arrOut ) ] ) ) {
            arrayDeleteAt( local.arrOut, arrayLen( local.arrOut ) );
        }
        return local.arrOut;
    }


    // Raw record -> canonical (cells joined by chr(31)).
    public string function canonical( required string record ) {

        local.r = arguments.record;

        // 1. Fully quoted. After replacing every  ","  no quote may remain, or a value held an
        //    escaped quote (or a literal ","), and only the tokenizer reads that exactly.
        if( len( local.r ) >= 2 && left( local.r, 1 ) == '"' && right( local.r, 1 ) == '"' ) {
            local.sInner = replace( mid( local.r, 2, len( local.r ) - 2 ), '"' & variables.sDelim & '"', variables.US, "all" );
            if( !find( '"', local.sInner ) ) { return local.sInner; }
        }

        // 2. No quotes at all: values cannot contain the delimiter.
        if( !find( '"', local.r ) ) { return replace( local.r, variables.sDelim, variables.US, "all" ); }

        // 3. Exact tokenizer.
        return arrayToList( parseFields( local.r ), variables.US );
    }


    public array function parseFields( required string record ) {
        local.arr = [];
        local.m = variables.oField.matcher( arguments.record );
        while( local.m.find() ) {
            local.sQuoted = local.m.group( javaCast( "int", 1 ) );
            if( !isNull( local.sQuoted ) ) {
                arrayAppend( local.arr, replace( local.sQuoted, '""', '"', "all" ) );
            } else {
                local.sBare = local.m.group( javaCast( "int", 2 ) );
                arrayAppend( local.arr, isNull( local.sBare ) ? "" : local.sBare );
            }
            if( !len( local.m.group( javaCast( "int", 3 ) ) ) ) { break; } // reached the end of the record
        }
        return local.arr;
    }

}
