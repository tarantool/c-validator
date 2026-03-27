#!/usr/bin/env tarantool
-- Tests for schema:check(data [, opts])

local t  = require('luatest')
local cv = require('cv')

local g = t.group('check')

local function schema(def)
    local s, err = cv.compile(def)
    assert(s ~= nil, 'compile failed: ' ..
        tostring(err and err[1] and
                 err[1].message or '?'))
    return s
end

local function check_ok(s, data, opts)
    local _, errs = s:check(data, opts)
    t.assert_equals(#errs, 0,
        'expected ok, got errors: ' ..
        tostring(errs[1] and
                 errs[1].message or '?'))
end

local function check_err(s, data, opts)
    local r, errs = s:check(data, opts)
    t.assert_equals(r, nil,
        'expected error, got ok')
    t.assert_is_not(errs, nil)
    t.assert_is_not(#errs, 0)
    return errs
end

-- -------------------------------------------------------
-- scalar: string
-- -------------------------------------------------------
g.test_scalar_string_ok = function()
    local s = schema('string')
    check_ok(s, 'hello')
end

g.test_scalar_string_err = function()
    local s = schema('string')
    local errs = check_err(s, 42)
    t.assert_equals(errs[1].type, 'TYPE_ERROR')
end

-- -------------------------------------------------------
-- scalar: number
-- -------------------------------------------------------
g.test_scalar_number_ok = function()
    local s = schema('number')
    check_ok(s, 3.14)
    check_ok(s, 0)
end

g.test_scalar_number_err = function()
    local s = schema('number')
    local errs = check_err(s, 'nope')
    t.assert_equals(errs[1].type, 'TYPE_ERROR')
end

-- -------------------------------------------------------
-- scalar: boolean
-- -------------------------------------------------------
g.test_scalar_boolean = function()
    local s = schema('boolean')
    check_ok(s, true)
    check_ok(s, false)
    check_err(s, 1)
end

-- -------------------------------------------------------
-- nullable
-- -------------------------------------------------------
g.test_nullable_ok = function()
    local s = schema({type = {'string', true}})
    check_ok(s, 'hello')
    check_ok(s, nil)
end

g.test_nullable_err = function()
    local s = schema({type = {'string', false}})
    check_err(s, nil)
end

-- -------------------------------------------------------
-- string constraints: min/max length
-- -------------------------------------------------------
g.test_string_min_length = function()
    local s = schema({type='string', min_length=3})
    check_ok(s, 'abc')
    check_ok(s, 'abcd')
    local errs = check_err(s, 'ab')
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
end

g.test_string_max_length = function()
    local s = schema({type='string', max_length=3})
    check_ok(s, 'abc')
    local errs = check_err(s, 'abcd')
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
end

-- -------------------------------------------------------
-- string constraints: match/pattern
-- -------------------------------------------------------
g.test_string_pattern = function()
    local s = schema({
        type  = 'string',
        match = '^%d+$',
    })
    check_ok(s, '123')
    local errs = check_err(s, 'abc')
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
end

-- -------------------------------------------------------
-- string enum
-- -------------------------------------------------------
g.test_string_enum = function()
    local s = schema({
        type = 'string',
        enum = {'a', 'b', 'c'},
    })
    check_ok(s, 'a')
    check_ok(s, 'c')
    local errs = check_err(s, 'd')
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
end

-- -------------------------------------------------------
-- number constraints: min/max/gt/lt
-- -------------------------------------------------------
g.test_number_min = function()
    local s = schema({type='number', min=0})
    check_ok(s, 0)
    check_ok(s, 1)
    check_err(s, -1)
end

g.test_number_max = function()
    local s = schema({type='number', max=10})
    check_ok(s, 10)
    check_err(s, 11)
end

g.test_number_gt = function()
    local s = schema({type='number', gt=0})
    check_ok(s, 1)
    check_err(s, 0)
end

g.test_number_lt = function()
    local s = schema({type='number', lt=10})
    check_ok(s, 9)
    check_err(s, 10)
end

-- -------------------------------------------------------
-- number enum
-- -------------------------------------------------------
g.test_number_enum = function()
    local s = schema({
        type = 'number',
        enum = {1, 2, 3},
    })
    check_ok(s, 1)
    check_err(s, 4)
end

-- -------------------------------------------------------
-- map: basic required fields
-- -------------------------------------------------------
g.test_map_ok = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
            age  = 'integer',
        },
    })
    check_ok(s, {name='Alice', age=30})
end

g.test_map_missing_field = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
            age  = 'integer',
        },
    })
    local errs = check_err(s, {name='Alice'})
    t.assert_equals(errs[1].type, 'UNDEFINED_VALUE')
end

g.test_map_wrong_field_type = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
        },
    })
    local errs = check_err(s, {name=123})
    t.assert_equals(errs[1].type, 'TYPE_ERROR')
    -- path should include field name
    t.assert_is_not(
        errs[1].path:find('name'), nil)
end

-- -------------------------------------------------------
-- map: optional field
-- -------------------------------------------------------
g.test_map_optional = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
            age  = 'integer?',
        },
    })
    check_ok(s, {name='Bob'})
    check_ok(s, {name='Bob', age=25})
end

-- -------------------------------------------------------
-- map: default applied
-- -------------------------------------------------------
g.test_map_default = function()
    local s = schema({
        type = 'map',
        properties = {
            name   = 'string',
            active = {type='boolean', default=true},
        },
    })
    local data = {name='Carol'}
    check_ok(s, data)
    t.assert_equals(data.active, true)
end

g.test_map_default_validate_only = function()
    local s = schema({
        type = 'map',
        properties = {
            name   = 'string',
            active = {type='boolean', default=true},
        },
    })
    local data = {name='Carol'}
    -- validate_only: default not applied, but ok
    check_ok(s, data, {validate_only=true})
    t.assert_equals(data.active, nil)
end

-- -------------------------------------------------------
-- map: unexpected fields
-- -------------------------------------------------------
g.test_map_unexpected_err = function()
    local s = schema({
        type = 'map',
        properties = {name = 'string'},
    })
    local errs = check_err(s,
        {name='X', extra='oops'})
    t.assert_equals(errs[1].type,
        'UNEXPECTED_KEY')
end

g.test_map_skip_unexpected = function()
    local s = schema({
        type = 'map',
        skip_unexpected_check = true,
        properties = {name = 'string'},
    })
    local data = {name='X', extra='oops'}
    check_ok(s, data)
    -- extra key removed
    t.assert_equals(data.extra, nil)
end

g.test_map_return_unexpected = function()
    local s = schema({
        type = 'map',
        skip_unexpected_check = true,
        return_unexpected     = true,
        properties = {name = 'string'},
    })
    local data = {name='X', extra='oops'}
    check_ok(s, data)
    -- extra key preserved
    t.assert_equals(data.extra, 'oops')
end

-- -------------------------------------------------------
-- map: rename via aliases
-- -------------------------------------------------------
g.test_map_rename_alias = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
        },
        rename = {nm = 'name'},
    })
    -- data uses alias 'nm' instead of 'name'
    local data = {nm = 'Alice'}
    check_ok(s, data)
    -- after check, key renamed to 'name'
    t.assert_equals(data.name, 'Alice')
    t.assert_equals(data.nm,   nil)
end

g.test_map_rename_alias_validate_only = function()
    local s = schema({
        type = 'map',
        properties = {
            name = 'string',
        },
        rename = {nm = 'name'},
    })
    local data = {nm = 'Alice'}
    -- validate_only: alias found, no rename
    check_ok(s, data, {validate_only=true})
    t.assert_equals(data.nm,   'Alice')
    t.assert_equals(data.name, nil)
end

-- -------------------------------------------------------
-- array: basic
-- -------------------------------------------------------
g.test_array_ok = function()
    local s = schema({
        type  = 'array',
        items = 'string',
    })
    check_ok(s, {'a', 'b', 'c'})
end

g.test_array_wrong_item = function()
    local s = schema({
        type  = 'array',
        items = 'string',
    })
    local errs = check_err(s, {'a', 2, 'c'})
    t.assert_equals(errs[1].type, 'TYPE_ERROR')
    -- path includes index
    t.assert_is_not(
        errs[1].path:find('%[2%]'), nil)
end

g.test_array_min_items = function()
    local s = schema({
        type      = 'array',
        min_length = 2,
    })
    check_ok(s, {1, 2})
    check_err(s, {1})
end

g.test_array_max_items = function()
    local s = schema({
        type      = 'array',
        max_length = 2,
    })
    check_ok(s, {1, 2})
    check_err(s, {1, 2, 3})
end

-- -------------------------------------------------------
-- oneof
-- -------------------------------------------------------
g.test_oneof_string = function()
    local s = schema({
        type = 'oneof',
        variants = {
            {type = 'string'},
            {type = 'number'},
        },
    })
    check_ok(s, 'hello')
    check_ok(s, 42)
    local errs = check_err(s, true)
    -- second pass adds variant errors first,
    -- ONEOF_ERROR is last
    t.assert_equals(errs[#errs].type, 'ONEOF_ERROR')
end

g.test_oneof_map = function()
    local s = schema({
        type = 'oneof',
        variants = {
            {
                type = 'map',
                properties = {
                    name = 'string',
                },
            },
            {
                type = 'map',
                properties = {
                    id = 'unsigned',
                },
            },
        },
    })
    check_ok(s, {name='Alice'})
    check_ok(s, {id=1})
    check_err(s, {foo='bar'})
end

-- -------------------------------------------------------
-- path in errors
-- -------------------------------------------------------
g.test_error_path_nested = function()
    local s = schema({
        type = 'map',
        properties = {
            user = {
                type = 'map',
                properties = {
                    age = 'integer',
                },
            },
        },
    })
    local errs = check_err(s,
        {user = {age = 'bad'}})
    t.assert_equals(errs[1].type, 'TYPE_ERROR')
    t.assert_is_not(
        errs[1].path:find('user'), nil)
    t.assert_is_not(
        errs[1].path:find('age'), nil)
end

-- -------------------------------------------------------
-- validate_only: no mutations
-- -------------------------------------------------------
g.test_validate_only_no_transform = function()
    local called = false
    local s = schema({
        type      = 'string',
        transform = function(v)
            called = true
            return v
        end,
    })
    check_ok(s, 'hello', {validate_only=true})
    t.assert_equals(called, false)
end

-- -------------------------------------------------------
-- error format: details always present
-- -------------------------------------------------------
g.test_error_has_details = function()
    local s = schema('string')
    local r, errs = s:check(42)
    t.assert_equals(r, nil)
    t.assert_type(errs[1].details, 'table',
        'details should always be a table')
    t.assert_equals(errs[1].details.expected_type,
        'string')
    t.assert_equals(errs[1].details.actual_type,
        'number')
    t.assert_equals(errs[1].details.value, 42)
end

g.test_value_error_details = function()
    local s = schema({type='number', min=10})
    local r, errs = s:check(5)
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
    t.assert_type(errs[1].details, 'table')
    t.assert_equals(errs[1].details.value, 5)
    t.assert_is_not(errs[1].details.min, nil)
end

g.test_unexpected_key_details = function()
    local s = schema({
        type = 'map',
        properties = {name = 'string'},
    })
    local r, errs = s:check({name='X', bad='oops'})
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].type, 'UNEXPECTED_KEY')
    t.assert_type(errs[1].details, 'table')
    t.assert_equals(
        errs[1].details.unexpected_key, 'bad')
end

-- -------------------------------------------------------
-- error format: name from schema
-- -------------------------------------------------------
g.test_error_has_name = function()
    local s = schema({
        type = 'string',
        name = 'my_field',
    })
    local r, errs = s:check(42)
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].name, 'my_field')
end

-- -------------------------------------------------------
-- VALUE_ERROR codes for string constraints
-- -------------------------------------------------------
g.test_string_constraint_value_error = function()
    local s = schema({type='string', min_length=5})
    local r, errs = s:check('hi')
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
    t.assert_equals(errs[1].details.min_len, 5)
end

g.test_string_pattern_value_error = function()
    local s = schema({
        type  = 'string',
        match = '^%d+$',
    })
    local r, errs = s:check('abc')
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
    t.assert_is_not(
        errs[1].details.match_string, nil)
end

g.test_enum_value_error = function()
    local s = schema({
        type = 'string',
        enum = {'a', 'b'},
    })
    local r, errs = s:check('c')
    t.assert_equals(r, nil)
    t.assert_equals(errs[1].type, 'VALUE_ERROR')
    t.assert_type(
        errs[1].details.enum_variants, 'table')
end

-- -------------------------------------------------------
-- transform on map field must be written back
-- -------------------------------------------------------

-- Regression: transform applied to a map field must be
-- written back into the parent table.
-- Previously cv_check_node mutated the stack copy but
-- never called cv_map_setfield to persist the change.
g.test_map_field_transform_writeback = function()
    -- simple scalar field with transform
    local s = schema({
        type = 'map',
        properties = {
            x = {
                type = 'number',
                transform = function(v)
                    return v * 10
                end,
            },
        },
    })
    local r, errs = s:check({x = 5})
    t.assert_equals(errs, {})
    t.assert_equals(r.x, 50)

    -- oneof field with transform: parent map transform
    -- must see the already-transformed child value
    local seen_by_parent
    local s2 = schema({
        type = 'map',
        properties = {
            field = {
                type = 'oneof',
                variants = {
                    {
                        type = 'number',
                        transform = function(v)
                            return v * 2
                        end,
                    },
                    'string',
                },
            },
        },
        transform = function(v)
            seen_by_parent = v.field
            return v
        end,
    })
    local r2, errs2 = s2:check({field = 3})
    t.assert_equals(errs2, {})
    -- child transform: 3 -> 6
    t.assert_equals(r2.field, 6)
    -- parent transform must see the child result
    t.assert_equals(seen_by_parent, 6)
end

-- -------------------------------------------------------
-- transform on array items must be written back
-- -------------------------------------------------------

-- Verify that cv_check_array already correctly writes
-- back transformed item values (regression guard).
g.test_array_item_transform_writeback = function()
    local s = schema({
        type = 'array',
        items = {
            type = 'number',
            transform = function(v)
                return v * 10
            end,
        },
    })
    local r, errs = s:check({1, 2, 3})
    t.assert_equals(errs, {})
    t.assert_equals(r, {10, 20, 30})
end

-- array items via oneof with transform in matched variant
g.test_array_item_transform_writeback_oneof = function()
    local s = schema({
        type = 'array',
        items = {
            type = 'oneof',
            variants = {
                {
                    type = 'number',
                    transform = function(v)
                        return v * 2
                    end,
                },
                'string',
            },
        },
    })
    local r, errs = s:check({3, 'hello', 5})
    t.assert_equals(errs, {})
    t.assert_equals(r, {6, 'hello', 10})
end

-- vim: ts=4 sts=4 sw=4 et
