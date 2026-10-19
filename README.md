# Export comparison (CFML, CSV and XLSX, with or without Apache POI)

Prove that a candidate export run holds the same data as a baseline run: after a performance
rewrite, a library swap, or a CSV-to-XLSX change. The files themselves nearly always differ (a
timestamp in the name, part boundaries that moved, a run-time column), so a plain byte compare says
"different" for identical data and can't tell you what changed when the data really did change.

## What it answers

The first line of every result:

| Verdict | Meaning |
|---|---|
| `BYTE-IDENTICAL` | every part file is byte-for-byte equal |
| `DATA-IDENTICAL` | same header, same rows in the same order; only the bytes differ (part splits, quoting, line endings, CSV vs XLSX) |
| `EQUIVALENT` | the same data once the differences you declared harmless are allowed: row order, value order inside multi-value cells, masked columns, number formatting. Each allowance is counted in the report |
| `DIFFERENT` | rows missing or added, cells changed, or columns changed |
| `UNKNOWN` | a side could not be read; the reason is under WARNINGS |

## Files

```
ExportCompare.cfc         the engine: compareRuns( baseline, candidate, options ), render( result )
readers/CsvReader.cfc     CSV, no libraries
readers/XlsxJdkReader.cfc XLSX WITHOUT POI: JDK zip + XML only
readers/XlsxPoiReader.cfc XLSX (and XLS) WITH Apache POI, streaming when excel-streaming-reader is present
CompareTask.cfc           command line, via CommandBox (no server needed)
DumpTask.cfc              write the rows a reader sees to a .tsv, to inspect
compare.cfm               web page (with Application.cfc: IP gate + allowed folders)
data/                     default allowed folder for the web page
```

## Running it

Command line (CommandBox; Lucee 5.4 and up):

```bash
box task run taskFile=CompareTask.cfc :baseline=D:/exports/baseline :candidate=D:/exports/candidate :key=AccountCode :mask=LastTouch
```

The exit code is 0 for identical or equivalent, 1 for different, 2 for unknown. `:json=true` prints the full result.

Web: put the runs under `data/` (or edit `allowedRoots` in `Application.cfc`), then:

```
compare.cfm?baseline=run1&candidate=run2&key=AccountCode&mask=LastTouch
compare.cfm?...&format=json
```

From CFML:

```cfml
oCompare = new path.to.ExportCompare();
res = oCompare.compareRuns( "/data/run1", "/data/run2", { key = "AccountCode", mask = "LastTouch" } );
writeOutput( oCompare.render( res ) );   // or use res.verdict, res.rows, res.samples ...
```

Each side is one export run: a file, an array of part files, or a directory. A directory is read
as every `.csv` / `.xlsx` / `.xls` in it, in name order, skipping names matching `exclude`
(default `PerfTimings`, so a timing log next to the parts is ignored).

## Options

| Option | Default | |
|---|---|---|
| `key` | none | column(s) that identify a row. Rows are paired by key and every changed cell is reported with both values. Never pair by position: many exports finalise unordered. A key that isn't unique falls back to multiset matching, with a warning |
| (no key) | | sorted multiset: rows are matched by whole content, so duplicates and seeded near-clones compare exactly. Differences are listed as rows only in one side |
| `mask` | none | columns to ignore: per-run values such as timestamps and run ids |
| `multiValue` | `\|` | delimiter of multi-value cells, compared as sets (`A\|B` = `B\|A`). Empty turns it off |
| `numericTolerant` | false | `12.50` = `12.5`, and an XLSX `14341.0` = a CSV `14341`, keys included. Off by default because it also equates `007` with `7`. Turn it on for CSV-vs-XLSX |
| `trim` | false | ignore leading and trailing whitespace |
| `reader` | auto | `csv`, `jdk` or `poi`. auto: `.csv` uses csv, `.xlsx` uses jdk (poi if a `poi` setting is given), `.xls` uses poi |
| `poi` | `{}` | where POI comes from (see below) |
| `poiValues` | stored | `stored`, or `display` (Excel's formatted text; avoid it for equality checks) |
| `dateMode` | iso | jdk reader: date cells as `yyyy-mm-dd[ HH:mm:ss]`, or `serial` |
| `sheet` | first | sheet name |
| `csvDelimiter` / `encoding` | `,` / utf-8 | |
| `headerRows` | 1 | header rows at the top of every part (repeated headers must match) |
| `sampleLimit` | 20 | differences listed per category |

Line breaks inside values are compared as LF on every reader (CRLF and CR become LF), because a
CSV can't carry that difference reliably.

## With and without POI

**Without POI** (`reader=jdk`, the default for `.xlsx`): the JDK alone, using `java.util.zip` and
regex/StAX over the sheet XML. It reads shared and inline strings, rich text, booleans, errors,
formula results and date styles, including the 1904 date system. Numbers come back as stored in
the file (`4615.0` if that's what the writer stored). Sheets up to `inMemoryMB` (300 MB
uncompressed) take a fast in-memory path; larger sheets are streamed with StAX. The XML parser
has DTDs and external entities disabled.

**With POI** (`reader=poi`): also reads legacy `.xls`. With `excel-streaming-reader` available,
rows are streamed; without it, POI loads the whole workbook, which needs several times the
unzipped size in heap. POI is located through the `poi` option:

```
{ "jars": [ "/opt/lib/poi" ] }                               jar files, or a directory of jars
{ "bundle": "spreadsheet-cfml", "version": "5.4.1.0",
  "bundlePath": "/path/to/lib-osgi.jar" }                    a Lucee OSGi bundle, installed on first use
{}                                                           the engine's classpath (lucee lib, or
                                                             this.javaSettings maven in Application.cfc)
```

The Spreadsheet CFML library ships a ready OSGi bundle (`lib-osgi.jar`) with POI 5.4.1 and
excel-streaming-reader inside, so a server that already uses that library can point `bundlePath`
at it.

The two readers render numbers differently (POI gives its shortest exact form: `4615`, `36.67`).
Compare like with like, or turn on `numericTolerant`.

## Speed (measured on CommandBox / Lucee 5.4, one laptop)

| Comparison | Time |
|---|---|
| CSV, 5 parts and 30 MB per side, 50,000 rows × 68 columns, by key | ~2.7 s |
| XLSX, 3 parts and 12 MB per side, 25,000 rows × 154 columns, no POI | ~28 s |
| the same with POI streaming | ~36 s |
| XLSX baseline vs CSV candidate, 25,000 rows, by key, numericTolerant | ~34 s |

## How it was verified

- CSV: an independent Python implementation of the same rules gave the same counts on two
  50,000-row runs: 2,500 multi-value reorders, and 1,000 masked run-stamp cells.
- XLSX: both readers' output was compared cell by cell with openpyxl on three real exports
  (2.47 million cells): no differences.
- A mutated copy, with one changed cell, one dropped row, one added row and every row shuffled,
  came out `DIFFERENT` with each change listed, both with and without a key.
- A run that drifted (one column changed on 24,999 rows) came out `DIFFERENT`, naming the column.
- The web page was tested on Lucee 7: text and JSON output, the folder whitelist (`../`
  refused), direct access to the components refused, and POI loaded through `bundlePath`.

## Limits

- One sheet per file. Rows that are entirely empty in an XLSX aren't invented, so an all-empty
  CSV row has no XLSX counterpart.
- Without a key, a changed row shows up as one row only in each side; give `key` for cell-level detail.
- Cell values containing ASCII control characters 28–31 aren't supported (XML can't hold them
  anyway).
- The web page prints row data: keep it on trusted networks (the default gate admits private
  addresses only) and keep `allowedRoots` narrow.
