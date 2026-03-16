# cv — Fast OpenAPI 3.1 Compatible Schema Validator for Tarantool

`cv` is a high-performance, schema-based data validator for Tarantool,
implemented in C. It is designed to validate data against **OpenAPI
3.1** schemas, while also providing an extended, user-friendly Lua
syntax for internal application logic.

Under the hood, `cv` parses your schema once into an optimized C
structure, achieving **~10x better performance** compared to pure-Lua
validators. It serves as a 100% drop-in replacement for the
`aeon.common.validator` module.

## Features

- **OpenAPI 3.1 Compatibility:** Use standard OpenAPI schema definitions
  (`type`, `properties`, `required`, `oneOf`, `minLength`, `pattern`, etc.).
- **Tarantool/Lua Native Extensions:**
  - Shorthand syntax for inline validation (e.g. `'string'`,
    `{'number', min = 10}`).
  - Support for Tarantool-specific types
    (`uuid`, `tuple`, `int64`, `uint64`, `box.NULL`).
  - Dealing with Lua table quirks (mixed integer and string keys).
  - Data mutations: `default` values, `rename` keys,
    and custom `transform` functions.
- **Fast:** Compiled schemas eliminate parsing overhead during the
  validation loop.
- **Serialization:** Export schemas back to strict OpenAPI 3.1 JSON/Lua
  tables (`schema:totable('openapi')`).

## Installation

### Via luarocks (Tarantool rocks)

```bash
tt rocks install cv
```

### From source

```bash
git clone https://github.com/tarantool/c-validator
cd c-validator
cmake -B build .
cmake --build build
cmake --install build
```

## Quick Start

### OpenAPI 3.1 Syntax

You can use strict OpenAPI 3.1 schema definitions to
validate external API requests.

```lua
local cv = require('cv')

local api_schema = cv.compile({
    type = 'object',
    properties = {
        id    = { type = 'integer', minimum = 1 },
        name  = { type = 'string' },
        email = { type = 'string', pattern = '^[^@]+@[^@]+$' }
    },
    required = { 'id', 'name' },
    additionalProperties = false -- reject unknown keys
})

local result, errors = api_schema:check(request_data)
if not result then
    return http_400_bad_request(errors)
end
```

### Extended Lua Syntax

For internal functions, writing full OpenAPI schemas can be verbose.
`cv` provides a shorthand syntax optimized for Lua logic, allowing you
to validate mixed tables (arrays + hashes) and apply default values or
renames.

```lua
local cv = require('cv')

local internal_schema = cv.compile({
    type = 'map',
    properties = {
        [1]   = 'unsigned', -- integer key!
        name  = 'string',
        age   = { type = 'integer', min = 0, max = 150 },
        tags  = { type = 'array', items = 'string' }
    },
    rename = { [1] = 'id' } -- rename input[1] to result.id
})

-- Validates the data, renames [1] to 'id', and returns the mutated object
local result, errs = internal_schema:check({ 42, name = 'Alice', age = 30 })
-- result is now: { id = 42, name = 'Alice', age = 30 }
```

## API Reference

### `cv.compile(def [, opts]) -> schema, errors`

Compiles a schema definition into an optimized object.

- `def` — Schema definition (table or shorthand string).
- `opts.raise_errors` — If `true`, raises a Lua error instead of
  returning an errors table on bad schemas.

Returns `schema, nil` on success, `nil, errors` on failure.

### `schema:check(data [, opts]) -> data, errors`

Validates and optionally transforms `data` in-place against the
compiled schema.

- `opts.validate_only` — Skips data mutations (defaults, rename, transforms).
- `opts.raise_errors` — Raises a Lua error on the first validation failure.

Returns `data, {}` on success, `nil, errors` on failure.

### `cv.check(data, schema_def [, opts]) -> data, errors`

Convenience function. Compiles the schema on the fly and checks the data.

```lua
-- equivalent to old: validator.check(data, schema)
local result, errs = cv.check(data, 'string')
local result, errs = cv.check(data, {type='map', ...})
```

### `schema:totable([format]) -> table`

Serializes the compiled schema back to a Lua table.

- `format` — `'tarantool'` (default, retains shorthand) or
  `'openapi'` (strict OpenAPI 3.1 format).

```lua
local oapi_spec = schema:totable('openapi')
```

### `cv.is_schema(v) -> bool`

Returns `true` if `v` is a compiled schema userdata object.

## Schema Types & Constraints

### Scalar Types

| OpenAPI type | Shorthand | Description |
|---|---|---|
| `string` | `'string'` | Lua string |
| `number` | `'number'` | Lua number, `int64`, or `uint64` |
| `integer` | `'integer'` | Integer number, `int64`, or `uint64` |
| (Tarantool) | `'unsigned'` | Non-negative integer, `int64 >= 0`, `uint64` |
| `boolean` | `'boolean'` | `true` or `false` |
| (Tarantool) | `'uuid'` | Tarantool `uuid` |
| (Tarantool) | `'tuple'` | Tarantool `tuple` |
| (Tarantool) | `'function'`| Lua function or callable table |
| (None) | `'any'` | Any value |
| (None) | `'nil'` | `nil` only |
| (None) | `'null'` | `nil` or `box.NULL` |

### Nullable & Optional

In OpenAPI 3.1, a type can be defined as an array to allow nulls.
In extended syntax, you can append `?` to a type string to make
it optional (allows `nil` and allows missing keys in maps).

```lua
{ type = {'string', 'null'} } -- OpenAPI 3.1 nullable
{ type = {'string', true} }   -- cv specific nullable
'string?'                     -- Shorthand for nullable and optional
```

### Map / Object Constraints

OpenAPI `object` maps to `map` or `table` in the extended syntax.

| OpenAPI field | Extended shorthand | Description |
|---|---|---|
| `properties` | `properties` | Defined keys and their schemas |
| `required` | `required` | Array of required keys |
| `additionalProperties` | `items` | Wildcard schema for all unknown values |
| (None) | `rename` | `{ [from] = 'to' }` renames keys before validating |
| (None) | `skip_unexpected_check` | If `true`, unknown keys are ignored (stripped) |
| (None) | `return_unexpected` | If `true`, unknown keys are kept in the result |

### Number Constraints

| OpenAPI field | Extended shorthand |
|---|---|
| `minimum` | `min` |
| `maximum` | `max` |
| `exclusiveMinimum` | `gt` |
| `exclusiveMaximum` | `lt` |

### String & Array Constraints

| OpenAPI field | Extended shorthand | Description |
|---|---|---|
| `minLength` | `min_length` | Minimum length |
| `maxLength` | `max_length` | Maximum length |
| `pattern` | `match` | Regular expression |
| `enum` | `enum` | Array of allowed values |
| `minItems` | `min_length` (array) | Minimum array length |
| `maxItems` | `max_length` (array) | Maximum array length |

### Callbacks (Extended Syntax Only)

You can attach Lua logic to any schema node:

```lua
{
    type = 'number',
    -- constraint: called after type/range checks.
    -- raise error() to signal failure.
    constraint = function(value)
        if value % 2 ~= 0 then error('must be even') end
    end,
    -- transform: mutates the value. Skipped in validate_only mode.
    transform = function(value)
        return value * 2
    end,
}
```

## Error Format

`cv` returns a structured table of errors on failure.
This format is fully compatible with `aeon.common.validator`.

```lua
{
    path    = '$.address.zip',  -- JSON path
    type    = 'TYPE_ERROR',     -- Error code
    message = 'Wrong type, expected string, got number',
    details = {
        expected_type = 'string',
        actual_type   = 'number',
        value         = 42,
        -- Code specific fields: min, max, match_string, etc.
    },
    name = 'zip_field',  -- Optional, from schema definition
}
```

### Error Codes

- `TYPE_ERROR`: Wrong Lua/cdata type.
- `VALUE_ERROR`: Constraint violation (`min`, `max`, `enum`, `pattern`).
- `CONSTRAINT_ERROR`: User `constraint` function raised an error.
- `TRANSFORM_ERROR`: User `transform` function raised an error.
- `UNDEFINED_VALUE`: Missing `required` field.
- `UNEXPECTED_KEY`: Map contains an undeclared key.
- `ONEOF_ERROR`: No `oneof` variant matched the data.

## Performance

Validation performance on a moderately complex object (10 fields,
nested arrays/maps) across 50,000 iterations:

```text
old aeon validator    86.8 us/call
new cv:check          17.3 us/call   (~5x faster overall)
new cv validate_only   9.2 us/call   (~9x faster pure validation)
```
*(Benchmark includes `deepcopy` overhead for the
input data on each iteration)*

## License

BSD 2-Clause
