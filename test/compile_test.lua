#!/usr/bin/env tarantool
-- Tests for cv.compile() and schema:totable()

local t = require('luatest')
local cv = require('cv')

local g = t.group('compile')

-- helpers
local function compile_ok(def)
    local schema, errors = cv.compile(def)
    t.assert_is_not(schema, nil,
        'expected schema, got nil for: ' ..
        tostring(def))
    t.assert_equals(errors, nil,
        'expected no errors')
    return schema
end

local function compile_err(def)
    local schema, errors = cv.compile(def)
    t.assert_equals(schema, nil,
        'expected nil schema')
    t.assert_is_not(errors, nil,
        'expected errors table')
    t.assert_is_not(#errors, 0,
        'expected non-empty errors')
    return errors
end

-- -------------------------------------------------------
-- short string forms
-- -------------------------------------------------------
g.test_short_string_forms = function()
    local types = {
        'any', 'boolean', 'string', 'number',
        'integer', 'unsigned', 'null', 'nil',
        'uuid', 'tuple', 'function',
    }
    for _, tp in ipairs(types) do
        local s = compile_ok(tp)
        local tbl = s:totable()
        t.assert_equals(tbl.type, tp,
            'type mismatch for ' .. tp)
        t.assert_equals(tbl.optional, false,
            'optional should be false for ' .. tp)
        t.assert_equals(tbl.nullable, false,
            'nullable should be false for ' .. tp)
    end
end

-- -------------------------------------------------------
-- optional '?' suffix
-- -------------------------------------------------------
g.test_optional_suffix = function()
    local types = {
        'any', 'boolean', 'string', 'number',
        'integer', 'unsigned', 'null', 'nil',
        'uuid', 'tuple', 'function',
    }
    for _, tp in ipairs(types) do
        local s = compile_ok(tp .. '?')
        local tbl = s:totable()
        t.assert_equals(tbl.type, tp,
            'type mismatch for ' .. tp .. '?')
        t.assert_equals(tbl.optional, true,
            'optional should be true for ' .. tp .. '?')
    end
end

-- -------------------------------------------------------
-- OpenAPI type aliases
-- -------------------------------------------------------
g.test_type_aliases = function()
    -- object -> map
    local s = compile_ok('object')
    t.assert_equals(s:totable().type, 'map')

    -- oneOf -> oneof
    local s2 = compile_ok({type = 'oneOf'})
    t.assert_equals(s2:totable().type, 'oneof')

    -- table -> map
    local s3 = compile_ok('table')
    t.assert_equals(s3:totable().type, 'map')
end

-- -------------------------------------------------------
-- table forms: {type=...}, {'type'}, {'type', default}
-- -------------------------------------------------------
g.test_table_forms = function()
    -- {type = 'string'}
    local s1 = compile_ok({type = 'string'})
    t.assert_equals(s1:totable().type, 'string')

    -- {'number'}
    local s2 = compile_ok({'number'})
    t.assert_equals(s2:totable().type, 'number')

    -- {'integer', 42}  -> default = 42
    local s3 = compile_ok({'integer', 42})
    local t3 = s3:totable()
    t.assert_equals(t3.type, 'integer')
    t.assert_equals(t3.default, 42)

    -- {type='boolean', default=true}
    local s4 = compile_ok({type='boolean', default=true})
    t.assert_equals(s4:totable().default, true)
end

-- -------------------------------------------------------
-- optional / nullable flags
-- -------------------------------------------------------
g.test_flags = function()
    local s = compile_ok({
        type = 'string',
        optional = true,
        nullable = true,
    })
    local tbl = s:totable()
    t.assert_equals(tbl.optional, true)
    t.assert_equals(tbl.nullable, true)
end

-- -------------------------------------------------------
-- name
-- -------------------------------------------------------
g.test_name = function()
    local s = compile_ok({type='number', name='myfield'})
    t.assert_equals(s:totable().name, 'myfield')
end

-- -------------------------------------------------------
-- string constraints
-- -------------------------------------------------------
g.test_string_constraints = function()
    local s = compile_ok({
        type = 'string',
        min_length = 1,
        max_length = 64,
        match = '^%w+$',
    })
    local tbl = s:totable()
    t.assert_equals(tbl.min_length, 1)
    t.assert_equals(tbl.max_length, 64)
    t.assert_equals(tbl.match, '^%w+$')

    -- OpenAPI aliases
    local s2 = compile_ok({
        type = 'string',
        minLength = 2,
        maxLength = 10,
        pattern   = '^%d+$',
    })
    local tbl2 = s2:totable()
    t.assert_equals(tbl2.min_length, 2)
    t.assert_equals(tbl2.max_length, 10)
    t.assert_equals(tbl2.match, '^%d+$')
end

-- -------------------------------------------------------
-- string enum
-- -------------------------------------------------------
g.test_string_enum = function()
    local s = compile_ok({
        type = 'string',
        enum = {'a', 'b', 'c'},
    })
    t.assert_equals(s:totable().enum, {'a', 'b', 'c'})
end

-- -------------------------------------------------------
-- number constraints
-- -------------------------------------------------------
g.test_number_constraints = function()
    local s = compile_ok({
        type = 'number',
        min = 0,
        max = 100,
        gt  = -1,
        lt  = 101,
    })
    local tbl = s:totable()
    t.assert_equals(tbl.min, 0)
    t.assert_equals(tbl.max, 100)
    t.assert_equals(tbl.gt,  -1)
    t.assert_equals(tbl.lt,  101)

    -- OpenAPI aliases
    local s2 = compile_ok({
        type    = 'integer',
        minimum = 1,
        maximum = 99,
        exclusiveMinimum = 0,
        exclusiveMaximum = 100,
    })
    local tbl2 = s2:totable()
    t.assert_equals(tbl2.min, 1)
    t.assert_equals(tbl2.max, 99)
    t.assert_equals(tbl2.gt,  0)
    t.assert_equals(tbl2.lt,  100)
end

-- -------------------------------------------------------
-- number enum
-- -------------------------------------------------------
g.test_number_enum = function()
    local s = compile_ok({
        type = 'number',
        enum = {1, 2, 3},
    })
    t.assert_equals(s:totable().enum, {1, 2, 3})
end

-- -------------------------------------------------------
-- constraint / transform (functions stored and returned)
-- -------------------------------------------------------
g.test_callbacks = function()
    local constraint = function(v) return v end
    local transform  = function(v) return v + 1 end

    local s = compile_ok({
        type       = 'number',
        constraint = constraint,
        transform  = transform,
    })
    local tbl = s:totable()
    t.assert_equals(tbl.constraint, constraint)
    t.assert_equals(tbl.transform,  transform)
end

-- -------------------------------------------------------
-- error: unknown type
-- -------------------------------------------------------
g.test_error_unknown_type = function()
    local errors = compile_err('foobar')
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
    t.assert_equals(errors[1].path, '$')
    t.assert_equals(errors[1].details.got, 'foobar')
end

-- -------------------------------------------------------
-- error: wrong pattern type
-- -------------------------------------------------------
g.test_error_bad_pattern = function()
    local errors = compile_err({
        type    = 'string',
        pattern = 123,
    })
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
    t.assert_equals(errors[1].path, '$.pattern')
end

-- -------------------------------------------------------
-- error: wrong enum element type for string
-- -------------------------------------------------------
g.test_error_bad_enum_string = function()
    -- mixed-type enum is now allowed at compile time;
    -- type mismatch is caught at validation time
    local s = compile_ok({
        type = 'string',
        enum = {'ok', 123},
    })
    t.assert_is_not(s, nil)
end

-- -------------------------------------------------------
-- mixed enum for number: allowed at compile time
-- -------------------------------------------------------
g.test_error_bad_enum_number = function()
    local s = compile_ok({
        type = 'number',
        enum = {1, 'oops'},
    })
    t.assert_is_not(s, nil)
end

-- -------------------------------------------------------
-- error: bad schema type (not string/table)
-- -------------------------------------------------------
g.test_error_bad_schema_type = function()
    local errors = compile_err(42)
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
    t.assert_equals(errors[1].path, '$')
end

-- -------------------------------------------------------
-- map / table / object: basic
-- -------------------------------------------------------
g.test_map_basic = function()
    for _, tp in ipairs({'map', 'table', 'object'}) do
        local s = compile_ok({type = tp})
        local tbl = s:totable()
        t.assert_equals(tbl.type, 'map',
            'type alias ' .. tp .. ' -> map')
        t.assert_equals(tbl.optional, false)
        t.assert_equals(tbl.nullable, false)
        -- no properties: unknown keys are accepted
        -- and returned (matches old validator)
        t.assert_equals(tbl.skip_unexpected_check,
            true)
        t.assert_equals(tbl.return_unexpected, true)
    end
end

-- -------------------------------------------------------
-- map with properties
-- -------------------------------------------------------
g.test_map_properties = function()
    local s = compile_ok({
        type = 'map',
        properties = {
            name = 'string',
            age  = {'integer', optional = true},
            active = {type = 'boolean',
                      default = true},
        },
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'map')
    t.assert_type(tbl.properties, 'table')
    t.assert_equals(tbl.properties.name.type,
        'string')
    t.assert_equals(tbl.properties.age.type,
        'integer')
    t.assert_equals(tbl.properties.age.optional,
        true)
    t.assert_equals(tbl.properties.active.type,
        'boolean')
    t.assert_equals(tbl.properties.active.default,
        true)
end

-- -------------------------------------------------------
-- map with items (wildcard)
-- -------------------------------------------------------
g.test_map_items = function()
    local s = compile_ok({
        type  = 'map',
        items = 'number',
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'map')
    t.assert_equals(tbl.items.type, 'number')
end

-- -------------------------------------------------------
-- map flags: skip_unexpected_check, return_unexpected
-- -------------------------------------------------------
g.test_map_flags = function()
    local s = compile_ok({
        type = 'map',
        skip_unexpected_check = true,
        return_unexpected     = true,
    })
    local tbl = s:totable()
    t.assert_equals(tbl.skip_unexpected_check, true)
    t.assert_equals(tbl.return_unexpected, true)
end

-- -------------------------------------------------------
-- map with rename
-- Sorted order: integers first (asc), then strings (lex)
-- -------------------------------------------------------
g.test_map_rename = function()
    local s = compile_ok({
        type = 'map',
        -- int keys: [1]->'one', [2]->'two'
        -- string keys: 'part'->1, 'index'->2
        rename = {[1]='one', [2]='two',
                  part=1, index=2},
    })
    local tbl = s:totable()
    t.assert_type(tbl.rename, 'table',
        'rename should be a table')
    -- integer from keys
    t.assert_equals(tbl.rename[1], 'one')
    t.assert_equals(tbl.rename[2], 'two')
    -- string from keys
    t.assert_equals(tbl.rename.part,  1)
    t.assert_equals(tbl.rename.index, 2)
end

g.test_map_rename_order = function()
    -- verify sort: int keys before string keys
    local s = compile_ok({
        type   = 'map',
        rename = {foo='bar', [3]='c', [1]='a'},
    })
    local tbl = s:totable()
    -- integers first
    t.assert_equals(tbl.rename[1], 'a')
    t.assert_equals(tbl.rename[3], 'c')
    -- string key
    t.assert_equals(tbl.rename.foo, 'bar')
end

-- -------------------------------------------------------
-- array: basic
-- -------------------------------------------------------
g.test_array_basic = function()
    local s = compile_ok({type = 'array'})
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'array')
    t.assert_equals(tbl.optional, false)
end

-- -------------------------------------------------------
-- array with items
-- -------------------------------------------------------
g.test_array_items = function()
    local s = compile_ok({
        type  = 'array',
        items = 'string',
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'array')
    t.assert_equals(tbl.items.type, 'string')
end

-- -------------------------------------------------------
-- array with nested map items
-- -------------------------------------------------------
g.test_array_nested = function()
    local s = compile_ok({
        type  = 'array',
        items = {
            type = 'map',
            properties = {
                x = 'number',
                y = 'number',
            },
        },
    })
    local tbl = s:totable()
    t.assert_equals(tbl.items.type, 'map')
    t.assert_equals(
        tbl.items.properties.x.type, 'number')
    t.assert_equals(
        tbl.items.properties.y.type, 'number')
end

-- -------------------------------------------------------
-- array min/max items (min_length/max_length aliases)
-- -------------------------------------------------------
g.test_array_min_max = function()
    local s = compile_ok({
        type       = 'array',
        min_length = 1,
        max_length = 10,
    })
    local tbl = s:totable()
    t.assert_equals(tbl.min_length, 1)
    t.assert_equals(tbl.max_length, 10)

    -- OpenAPI aliases
    local s2 = compile_ok({
        type     = 'array',
        minItems = 2,
        maxItems = 5,
    })
    local tbl2 = s2:totable()
    t.assert_equals(tbl2.min_length, 2)
    t.assert_equals(tbl2.max_length, 5)
end

-- -------------------------------------------------------
-- deep nesting: map -> array -> map
-- -------------------------------------------------------
g.test_deep_nesting = function()
    local s = compile_ok({
        type = 'map',
        properties = {
            users = {
                type  = 'array',
                items = {
                    type = 'map',
                    properties = {
                        id   = 'unsigned',
                        name = 'string',
                    },
                },
            },
        },
    })
    local tbl = s:totable()
    local users = tbl.properties.users
    t.assert_equals(users.type, 'array')
    local item = users.items
    t.assert_equals(item.type, 'map')
    t.assert_equals(item.properties.id.type,
        'unsigned')
    t.assert_equals(item.properties.name.type,
        'string')
end

-- -------------------------------------------------------
-- error: bad property schema
-- -------------------------------------------------------
g.test_error_bad_property = function()
    local errors = compile_err({
        type = 'map',
        properties = {
            foo = 'badtype',
        },
    })
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
    t.assert_equals(errors[1].path, '$.foo')
end

-- -------------------------------------------------------
-- oneof: tarantool style
-- -------------------------------------------------------
g.test_oneof_tarantool = function()
    local s = compile_ok({
        type = 'oneof',
        variants = {
            {type = 'string'},
            {type = 'number'},
        },
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'oneof')
    t.assert_type(tbl.variants, 'table')
    t.assert_equals(#tbl.variants, 2)
    t.assert_equals(tbl.variants[1].type, 'string')
    t.assert_equals(tbl.variants[2].type, 'number')
end

-- -------------------------------------------------------
-- oneof: OpenAPI style {oneOf = {...}}
-- -------------------------------------------------------
g.test_oneof_openapi_style = function()
    local s = compile_ok({
        oneOf = {
            {type = 'string'},
            {type = 'integer'},
        },
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'oneof')
    t.assert_equals(#tbl.variants, 2)
    t.assert_equals(tbl.variants[1].type, 'string')
    t.assert_equals(tbl.variants[2].type, 'integer')
end

-- -------------------------------------------------------
-- oneof: type='oneof' + oneOf= is valid
-- -------------------------------------------------------
g.test_oneof_combined = function()
    local s = compile_ok({
        type  = 'oneof',
        oneOf = {
            {type = 'boolean'},
            {type = 'null'},
        },
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'oneof')
    t.assert_equals(#tbl.variants, 2)
end

-- -------------------------------------------------------
-- oneof: error when type != oneof but oneOf present
-- -------------------------------------------------------
g.test_oneof_conflict_error = function()
    local errors = compile_err({
        type  = 'string',
        oneOf = {{type = 'number'}},
    })
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
    t.assert_equals(errors[1].path, '$.oneOf')
end

-- -------------------------------------------------------
-- nullable via type = {'string', true}
-- -------------------------------------------------------
g.test_nullable_type_array = function()
    local s = compile_ok({type = {'string', true}})
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'string')
    t.assert_equals(tbl.nullable, true)

    local s2 = compile_ok({type = {'number', false}})
    local tbl2 = s2:totable()
    t.assert_equals(tbl2.nullable, false)
end

-- -------------------------------------------------------
-- nullable type array: errors
-- -------------------------------------------------------
g.test_nullable_type_array_errors = function()
    -- wrong number of elements
    local e1 = compile_err({
        type = {'string', true, 'extra'},
    })
    t.assert_equals(e1[1].type, 'SCHEMA_ERROR')

    -- second element not boolean
    local e2 = compile_err({
        type = {'string', 'yes'},
    })
    t.assert_equals(e2[1].type, 'SCHEMA_ERROR')
end

-- -------------------------------------------------------
-- required for map
-- -------------------------------------------------------
g.test_map_required = function()
    local s = compile_ok({
        type = 'map',
        properties = {
            id   = 'unsigned',
            name = 'string?',
        },
        required = {'id'},
    })
    local tbl = s:totable()
    -- id: not optional (required)
    t.assert_equals(
        tbl.properties.id.optional, false)
    -- name: optional (? suffix)
    t.assert_equals(
        tbl.properties.name.optional, true)
end

-- -------------------------------------------------------
-- required conflict: field in required but optional
-- -------------------------------------------------------
g.test_map_required_conflict = function()
    local errors = compile_err({
        type = 'map',
        properties = {
            foo = 'string?',
        },
        required = {'foo'},
    })
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
end

-- -------------------------------------------------------
-- required: field not in properties → error
-- -------------------------------------------------------
g.test_map_required_missing = function()
    local errors = compile_err({
        type = 'map',
        properties = {
            bar = 'number',
        },
        required = {'baz'},
    })
    t.assert_equals(errors[1].type, 'SCHEMA_ERROR')
end

-- -------------------------------------------------------
-- totable('openapi'): basic scalar aliases
-- -------------------------------------------------------
g.test_totable_openapi_scalar = function()
    local s = compile_ok({
        type       = 'number',
        min        = 0,
        max        = 100,
        gt         = -1,
        lt         = 101,
    })
    local tbl = s:totable('openapi')
    t.assert_equals(tbl.type, 'number')
    t.assert_equals(tbl.minimum,          0)
    t.assert_equals(tbl.maximum,          100)
    t.assert_equals(tbl.exclusiveMinimum, -1)
    t.assert_equals(tbl.exclusiveMaximum, 101)
    -- tarantool names should be absent
    t.assert_equals(tbl.min, nil)
    t.assert_equals(tbl.max, nil)
end

-- -------------------------------------------------------
-- totable('openapi'): string aliases
-- -------------------------------------------------------
g.test_totable_openapi_string = function()
    local s = compile_ok({
        type       = 'string',
        min_length = 1,
        max_length = 64,
        match      = '^%w+$',
    })
    local tbl = s:totable('openapi')
    t.assert_equals(tbl.minLength, 1)
    t.assert_equals(tbl.maxLength, 64)
    t.assert_equals(tbl.pattern,   '^%w+$')
    t.assert_equals(tbl.min_length, nil)
    t.assert_equals(tbl.match,      nil)
end

-- -------------------------------------------------------
-- totable('openapi'): map -> object + required
-- -------------------------------------------------------
g.test_totable_openapi_map = function()
    local s = compile_ok({
        type = 'map',
        properties = {
            id   = 'unsigned',
            name = 'string?',
        },
    })
    local tbl = s:totable('openapi')
    t.assert_equals(tbl.type, 'object')
    t.assert_type(tbl.properties, 'table')
    -- id is not optional → in required
    t.assert_type(tbl.required, 'table')
    local req = {}
    for _, v in ipairs(tbl.required) do
        req[v] = true
    end
    t.assert_equals(req.id,   true)
    t.assert_equals(req.name, nil)
end

-- -------------------------------------------------------
-- totable('openapi'): nullable → type = [t, "null"]
-- -------------------------------------------------------
g.test_totable_openapi_nullable = function()
    local s = compile_ok({
        type     = {'string', true},
    })
    local tbl = s:totable('openapi')
    t.assert_type(tbl.type, 'table')
    t.assert_equals(tbl.type[1], 'string')
    t.assert_equals(tbl.type[2], 'null')
end

-- -------------------------------------------------------
-- totable('openapi'): oneof → {oneOf = [...]}
-- -------------------------------------------------------
g.test_totable_openapi_oneof = function()
    local s = compile_ok({
        type     = 'oneof',
        variants = {
            {type = 'string'},
            {type = 'number'},
        },
    })
    local tbl = s:totable('openapi')
    -- no 'type' key at top level for oneof
    t.assert_equals(tbl.type, nil)
    t.assert_type(tbl.oneOf, 'table')
    t.assert_equals(#tbl.oneOf, 2)
    t.assert_equals(tbl.oneOf[1].type, 'string')
    t.assert_equals(tbl.oneOf[2].type, 'number')
end

-- -------------------------------------------------------
-- totable('openapi'): array min/maxItems
-- -------------------------------------------------------
g.test_totable_openapi_array = function()
    local s = compile_ok({
        type       = 'array',
        min_length = 1,
        max_length = 10,
        items      = 'string',
    })
    local tbl = s:totable('openapi')
    t.assert_equals(tbl.minItems, 1)
    t.assert_equals(tbl.maxItems, 10)
    t.assert_equals(tbl.items.type, 'string')
    t.assert_equals(tbl.min_length, nil)
end

-- -------------------------------------------------------
-- map with integer keys in properties
-- -------------------------------------------------------
g.test_map_integer_keys = function()
    local s = compile_ok({
        type = 'map',
        properties = {
            [1] = 'string',
            [2] = 'number',
            name = 'string',
        },
    })
    local tbl = s:totable()
    t.assert_type(tbl.properties, 'table')
    t.assert_equals(tbl.properties[1].type, 'string')
    t.assert_equals(tbl.properties[2].type, 'number')
    t.assert_equals(tbl.properties.name.type, 'string')
end

-- -------------------------------------------------------
-- aliases: rename builds aliases on matching props
-- -------------------------------------------------------
g.test_map_rename_aliases = function()
    -- rename: [1]->'id', 'uid'->'id'
    -- prop 'id' should get aliases [1] and 'uid'
    -- We verify indirectly via totable: rename is
    -- preserved, and schema compiles without errors.
    local s = compile_ok({
        type = 'map',
        properties = {
            id   = 'unsigned',
            name = 'string',
        },
        rename = {[1] = 'id', uid = 'id'},
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'map')
    -- rename round-trips correctly
    t.assert_equals(tbl.rename[1],   'id')
    t.assert_equals(tbl.rename.uid,  'id')
    -- props still intact
    t.assert_equals(tbl.properties.id.type,   'unsigned')
    t.assert_equals(tbl.properties.name.type, 'string')
end

-- -------------------------------------------------------
-- aliases: rename target not in properties -> ok,
-- just no alias written (no error)
-- -------------------------------------------------------
g.test_map_rename_no_target_prop = function()
    -- rename 'foo'->'bar', but 'bar' is not in props
    local s = compile_ok({
        type = 'map',
        properties = {
            baz = 'string',
        },
        rename = {foo = 'bar'},
    })
    local tbl = s:totable()
    t.assert_equals(tbl.type, 'map')
    t.assert_equals(tbl.rename.foo, 'bar')
    t.assert_equals(tbl.properties.baz.type, 'string')
end

-- vim: ts=4 sts=4 sw=4 et
