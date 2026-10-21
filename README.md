# Graphgen

A semi-executable data definition language for filtering, transforming, and
plotting recorded flight data.

## Problem statement

When working on the GNC code for the rocketry airbrakes program, I generate a LOT
of data from different program runs. That data then needs to be easily convertible
into a graph. Since re-generating program data is usually quite expensive, I should
also be able to filter and annotate that data without having to re-run the program.

The old solution was a vibecoded JSON interpreter. However, that was really bad and
slow.

## Solution

The new solution is graphgen: a semi-executable data definition language.

Data files are columns of `f32` frames. A `.graph` file declares which data file to
use, how to filter it, which values to plot, and what annotations to place. The Zig
program parses the `.graph` file into a typed Zig value, emits bytecode for every
expression, and interprets that bytecode over the recorded frames.

There are two independent pipelines in the repository:

- `plot` / JSON: the legacy JSON frontend (`gthing2.json`) compiled through
  `first`/`second`/`third` and `interpret`.
- `graph` / `.graph`: the new typed parser and graph backend.

The Python wrapper `debuggraph2.py` drives either pipeline and renders the result
with matplotlib.

## Requirements

- Zig 0.17.0
- Python 3.13 with `uv` and `matplotlib` (for the Python wrapper)

## Building and testing

```sh
zig build                # build zig-out/bin/debuggraph_zig
zig build -Doptimize=ReleaseFast
zig build check          # compile check
zig build test           # run all tests
zig fmt src
```

Run the executable through `zig build run -- ...` or directly
`./zig-out/bin/debuggraph_zig ...`.

## Command-line interface

```
debuggraph_zig <subcommand> [...]
```

### `graph <file.graph> [--out=human|bare|none]`

Parse and execute a `.graph` file. `human` (the default) prints comma-separated
frame values and annotation text. `bare` prints the text header followed by raw
little-endian `f32` frames. `none` runs everything but suppresses chart output
(useful for benchmarks/validation).

```sh
zig build run -- graph newschema.graph
zig build run -- graph newschema.graph --out=bare
```

### `plot <file.json> [--out=human|bare|none]`

Run the legacy JSON pipeline. The JSON references a data file and declares one or
more plots. This still works and is what `debuggraph2.py plot` uses for `.json`
inputs. All plots in a config must reference the same data file.

### `parse <file.graph>`

Parse the file and print the debug bytecode listing for every function/value
reference. This does not read or execute data.

### `list_keys [debug_file]`

Print the column names in a debug data file (default `./debug_out.txt`).

### `resultsof [config.json]`

Print the output paths declared by a legacy JSON config (default `./gthing2.json`).

### `cool`

Internal benchmark against a hardcoded large data file.

## Data file formats

Data files are columns of frames. A column has a name, a starting frame (`skip`),
and an array of `f32` values. Missing values are represented by `NaN`, which the
runtime treats as "no data" when filtering and reducing.

### Legacy text format

One value per line:

```
.0..timestamp_s: 1.0
.0..pos_m.z: 3.1
.0..kalmanPos_m.x: 2.0
.1..timestamp_s: 1.2
...
```

The parser expects `.`, the frame number, `.`, the key, `:`, and a float. Columns
are discovered as they appear in each frame.

### V2 format (recommended because it's like a billion times faster to parse)

```
!v2
mode=raw
<field count>
<field name>
<field name>
...
```

Then for each field:

```
<field name>
<baseFrame>
<valueCount>
```

followed in `raw` mode by a literal `!`, `valueCount * 4` bytes of raw `f32`
(little-endian on typical targets), and a newline. In `human` mode the values are
plain text lines instead. Fields may be written in any order: they are matched by
name. `debug_out_v2_small.txt` is an example.

## `.graph` language

### Lexical rules

- `;` starts a comment that runs to the end of the line.
- Statements are separated by newlines.
- Strings are single- or double-quoted, single-line, with no escape sequences.
    - NOTE: this rule might change in the future. I have it around just because it makes parsing a little easier
- Identifiers/keys contain `A-Z`, `a-z`, `0-9`, and `_`.
- Keywords (`fn`, `import`, `foreign`) cannot be used as identifiers; doing so is a
  diagnostic (`KeywordAsIdentifier`).
- Object keys and values are separated by whitespace, not `:`.

### Top level

```
use "./debug_out_v2_small.txt"

fn m_to_ft(input) = input * 3.28

graph {
    ...
}
```

`use` names the data file. Strings are stored as slices into the source file.
`fn name(params) = expression` defines a function. Functions and labelled values
may be used before their definition: parsing emits bytecode and resolves references
in a later cleanup step. Recursive definitions are not supported.

### References and expressions

Expressions support:

- float numbers, including unary `-`
- `.key` data references
- `#name` references to a labelled bytecode value
- function parameters and function calls
- `+ - * /` with C precedence (left-associative)
- comparisons `> < >= <=`
- parentheses

Data references accept an optional access suffix:

| Syntax | Meaning |
| --- | --- |
| `.key` | value at the current frame |
| `.key:current` | value at the current frame |
| `.key:prev` | value at the previous frame |
| `.key:first` | first non-NaN value in the current filter window |
| `.key:last` | last non-NaN value in the current filter window |
| `.key:min` | minimum non-NaN value in the window |
| `.key:max` | maximum non-NaN value in the window |
| `.key:mean` | mean of non-NaN values in the window |

Comparisons are filters rather than booleans: `a > b` evaluates to `a` when the
comparison passes and to `NaN` when it fails. This lets filter expressions double
as values and lets the runtime track where the condition changes. The same applies
to `<`, `>=`, and `<=`.

### Labels

```
x {
    value #x = .timestamp_s
}
y {
    value #z = m_to_ft(.kalmanPosZ_m_agl)
}
annotation {
    line !#z
    x !#x
}
```

`#name` after a key declares a label for a bytecode-valued field. `!#name` reuses
that bytecode without re-emitting it. Labels may only be attached to bytecode
fields; attaching one to a string or number is a `TypeMismatch`. Referring to an
unknown label is `Undefined`.

### Graph structure

The graph backend expects this shape (`src/backends/graph.zig`):

```
graph {
    saveto "./plots/output.png"

    filter {
        left {
            value = .timestamp_s > 3800
            hint monotonic
        }
        right {
            value = .worldSpace.acc_mps2.z >= -80
            hint spike
        }
    }

    x {
        value #x = .timestamp_s
        title "timestamp (s)"
    }

    y {
        value #z = m_to_ft(.kalmanPosZ_m_agl)
        title "kalman pos z"
    }
    y { ... }

    annotation {
        line !#z
        select max
        x !#x
        y !#z
        text "Final apogee: {1} ft"
        value = #z
        arrow {
            dx -5
            dy -100
        }
    }
    annotation {
        line !#z
        select first
        x !#x
        y !#z
        text "First value: {2} ft"
        value = #z
        arrow {
            dx 5
            dy 100
        }
    }
}
```

`saveto`, `filter`, and `x` are required. `y` and `annotation` are repeated keys that
accumulate into slices: both may appear any number of times (including zero), and
each `annotation` block produces one annotation in the output.

Filter sections:

- `value`: bytecode expression. A non-NaN result passes; NaN fails.
- `hint`: `monotonic`, `spike`, or `none`.
  - `monotonic`: assumes the predicate is monotonic and binary-searches for the
    boundary.
  - `spike`: skips isolated values at the edge until it finds a passing run
    surrounded by failing frames (eg you can look for the launch frame of the rocket by running a spike filter over vertical acceleration)
  - `none`: scan inward from the edge one frame at a time.

The left bound is inclusive and the right bound is exclusive. If the predicate
already passes at the edge, that side is unrestricted.

Axes:

- `x`: one axis; provides the x value for each frame.
- `y`: one or more axes; every y must be non-NaN for a frame to be emitted. Up to
  31 y-axes are supported (`frameData` has 32 slots including x).

Annotations:

Each `annotation` block has the following fields and is evaluated independently
against the same filtered frames:

- `line`: bytecode evaluated every frame to find candidates and to decide whether
  data exists at all.
- `select`: `first`, `last`, `min`, or `max` of the `line` values over the emitted
  frames.
- `x` / `y`: bytecode evaluated at the selected frame.
- `value`: bytecode evaluated at the selected frame and substituted into `text`.
- `text`: supports `{N}` placeholders, which format `value` with `N` decimal
  places. `{}` formats without rounding. Escaping literal braces is not supported.
- `arrow.dx` / `arrow.dy`: offset from the annotation point to the text.

If the selected frame or any component of an annotation is NaN, that annotation is
replaced by `SKIP`; the other annotations are still emitted.

### Lists (arrays)

There is no separate list/array syntax such as `[...]` or commas. A field has the
Zig type `[]T` (a slice) and the corresponding key is simply repeated once per
element; the parser appends each element in source order:

```zig
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Config = struct {
    name: []const u8,
    point: []Point,
    item: []f32,
};
```

```
name "example"
point {
    x 1
    y 2
}
point {
    x 3
    y 4
}
item 10
item 20
item 30
```

This produces `point = [{ 1, 2 }, { 3, 4 }]` and `item = { 10, 20, 30 }`. Arrays
are materialized at the end of parsing, so a repeated key may be interleaved with
other keys. `[]const u8` is the exception: it is treated as a single scalar string,
not a list of bytes. A list field itself cannot have a `#label`; labels can only be
attached to non-list bytecode fields.

In the graph backend, `y` and `annotation` are lists of structs, which is why each
`y { ... }` or `annotation { ... }` block is a new element.

## Typed parser

`src/parse/parse.zig` exposes a reflection-driven parser:

```zig
var parser: parse.ParserPass1 = .{ ... };
var parsed = try parser.pass(gpa, SomeType, &diagnostic);
```

Supported field types:

- floats and integers (`parseNumber`)
- `[]const u8` strings
- nested structs (`parseObject` recursively)
- enums matched by field name
- slices of any supported type (`[]T`): the corresponding key may be repeated and
  each occurrence is appended
- bytecode fields: any struct with `pub const special: SpecialTypes = .bytecode`
  and integer/enum `start`/`len` handles (see `src/parse/types.zig`)

Struct fields are required unless they have a default value. Unknown keys produce
`UnknownField`, duplicate keys `AlreadyDefined`, and missing required keys
`MissingField`. Diagnostics carry a source reference and optional note chain.

Bytecode restrictions can be enforced per field type by adding:

```zig
pub const restrictions: struct {
    keyrefs: bool = true,
    axisrefs: bool = true,
} = .{};
```

`src/parse/resulttype.zig` provides a `Bytecode(keyrefs, axisrefs)` helper for this.
Restrictions are checked while parsing expressions (`checkBytecodeRestrictions`).

## Bytecode and interpreter

Each expression is compiled to a compact bytecode stream in
`src/parse/bytecode.zig`. Operations push/pop an `f32` value stack:

- keyref pushes (with access type first/last/min/max/mean/current/prev)
- axis pushes (a bytecode reference plus a reduction access type)
- literal pushes
- function argument pushes (reverse-indexed)
- arithmetic, comparison, negation, and special math functions
  (`ln`, `exp`, `max`, `min`, `sqrt`, `abs`, `pow`)
- `call` with a bytecode reference and argument count

The interpreter evaluates a bytecode range at a frame. Access reductions evaluate
the same range across the current filter window. Results are cached per
keyref/bytecode reference and filter window. Missing frames and failed comparisons
yield `NaN`.

Frame columns are stored with a `skip` (first frame number); lookups subtract it and
return `NaN` outside the column's range. When loading a data file, only columns
referenced by the bytecode are kept; `renameKeyrefs` remaps keyref ids to the loaded
column order and leaves unmatched keyrefs pointing at empty frames.

The graph backend runs:

1. parse the data file,
2. keep referenced columns and compute `maxFrame`,
3. remap keyrefs,
4. resolve filter bounds,
5. for each frame in the window, evaluate x, every y, and each annotation `line`,
6. emit frames and each selected annotation.

## Output format

`--out=human` and `--out=bare` share a text header:

```
CHART
SAVE:<saveto>
TITLE:
x:<x title>
width:0
height:0
dpi:0
font.title:0
font.xlabel:0
font.ylabel:0
font.legend:0
font.tick:0

<number of y axes>
y:<title>
...
```

`human` then prints one line per frame:

```
<x>, <y0>, <y1>, ...
```

`bare` instead writes `(1 + number_of_y) * 4` bytes per frame with no separators
(native `f32` bytes, little-endian on x86).

Both then print:

```
ANNOTATIONS
1
x:<value>
y:<value>
text:
BEGIN
<rendered text>
END
type:text
arrow.dx:<dx>
arrow.dy:<dy>
END
```

If one annotation cannot be produced, its block is just `SKIP\n`; the remaining
annotations are still emitted. `--out=none` suppresses all chart and annotation
output while still parsing data and executing frame expressions.

## Python wrapper (`debuggraph2.py`)

```
uv run debuggraph2.py graph newschema.graph
uv run debuggraph2.py plot gthing2.json
uv run debuggraph2.py plot newschema.graph     # .graph routes to graph
uv run debuggraph2.py resultsof gthing2.json
uv run debuggraph2.py list_keys debug_out_v2_small.txt
```

The wrapper builds the Zig binary in `ReleaseFast`, runs it with `--out=bare`,
parses the text/binary stream, and renders each chart with matplotlib. It uses the
chart's `saveto` path to write the image and also applies `{N}` annotation text,
arrows, and the available style fields (font size, color, bbox).

## Project layout

```
build.zig                  build/test/check steps
src/main.zig               CLI subcommands and legacy plot pipeline
src/root.zig               module root / public exports
src/fileref.zig            source references and diagnostics
src/parse/lexer.zig        tokenizer
src/parse/parse.zig        typed parser + bytecode emission
src/parse/bytecode.zig     bytecode format, interpreter, filters, keyref remap
src/parse/types.zig        bytecode field helpers
src/parse/resulttype.zig   configurable bytecode field helper
src/backends/graph.zig     .graph schema, frame loop, chart/annotation output
src/parse_txt.zig          legacy and v2 data file parsing
src/passes/                legacy JSON compiler and interpreter
debuggraph2.py             matplotlib frontend
newschema.graph            example .graph file
debug_out_v2_small.txt     example v2 data file
```

## Limitations / notes

- Function recursion is not supported.
- Strings have no escapes and cannot span lines.
- Keyword names are reserved.
- `import`/`foreign` syntax is reserved in the grammar but not implemented.
- The `.graph` backend emits one annotation per `annotation` block; each block
  tracks its own `line` values independently.
- Bare output uses native float byte order.

## Future ideas

- editor support route: lsp, highlights, vscode extension, etc
- language improvement route: dylibs, importing, modules, stdlib, etc
