--
-- NAME -- validator
--
-- SYNOPSIS
--
-- local validator = require 'aeon.common.validator'
--
-- local fields, problems = validator.check(myobject, object_schema, opts)
--
-- DESCRIPTION
--
-- Each object can be described by the lua table, that required
-- at least one field `type`. `type` is a string:
--
-- - 'boolean' - Lua boolean
-- - 'string' - Lua string
-- - 'number' - Lua number
-- - 'integer' - Lua number (integer) and Tarantool integer
-- - 'unsigned' - integer >= 0
-- - 'table' or 'map' - Lua table as assotiated array
-- - 'array' - Lua table as common array
-- - 'uuid' - Tarantool uuid
-- - 'tuple' - Tarantool tuple
-- - 'nil' - nil value
-- - 'any' - any value
--
-- If type description contains only type, it can be folded to string.
--
-- Example:
--
--      validator.check(10, { type = 'number' })
--      validator.check(10, 'number')                -- the same
--
-- If a field is optional, You can use `?` symbol in the type name.
--
-- Example:
--      validator.check(value, { type = 'string?' })
--      validator.check(value, 'string?')
--
-- Available options:
--  - disable_transformations: Disables all object transformations defined
--    in the schema (applying default values, renaming map keys, executing
--    a custom function).
--
-- --
-- RETURN VALUE
--
-- The validator returns a pair with:
-- - result object
-- - list of the object problems
--
-- Note: if one or more problems found, result object can be inconsistent.
--
-- Result object contains fields with default values.
--
-- --
-- FOUND PROBLEMS
--
-- All found problems stores in one Lua table. Each problem description
-- is Lua table, too. The table contains the following keys:
--  - type -- problem type (example: 'TYPE_ERROR', etc).
--  - message -- problem description (example: 'Undefined value', etc).
--  - path -- is a jsonpath for found problem (example: '$.a.b[5].c').
--
-- DEFAULT VALUES
--
-- The validator can enrich input object by default values. Example
--
--      local full_object, problems = validator.check(
--          {},
--          {
--              type = 'map',
--              properties = {
--                  a = { type = 'string', default = 'Hello, world' },
--                  b = { type = 'boolean', default = false }
--              }
--          }
--      )
--      assert(full_object == { a = 'Hello, world', b = false })
--
-- --
-- RENAME
--
-- The validator can rename fields in a table or map. To do this, you need to
-- define a "rename" field with the following syntax:
-- rename = {alias1 = name1, alias2 = name2, ...}.
--
-- If a field is renamed to a new name, the old value with that name is lost.
-- If there is more than one field that is renamed to the same name, the
-- resulting value will be the value of one of those fields.
--
-- Example:
--      local full_object = validator.check(
--          {123, a = 'asd', b = 'qwe', one = 'zxc'},
--          {
--              type = 'map',
--              rename = {
--                  [1] = b,
--                  one = c,
--              }
--              properties = {
--                  a = { type = 'string' },
--                  b = { type = 'number' },
--                  c = { type = 'string' },
--              }
--          }
--      )
--      assert(full_object == { a = 'asd_1', b = 123, c = 'zxc' })
--
-- Please note that the renaming will occur before the table or map validation.
--
-- --
-- TRANSFORMATION
--
-- The validator can transform the input object using the provided function.
-- A transformation will be attempted if a transformation function is provided,
-- but the result will only be valid if there were no errors during the
-- validation and transformation of the input object. The transformation will be
-- attempted after validation, if necessary, after setting the default value.
--
--      local function func_1(value)
--          return value .. '_1'
--      end
--      local function func_2(value)
--          return value + 1
--      end
--      local full_object, problems = validator.check(
--          {a = 'asd'},
--          {
--              type = 'map',
--              properties = {
--                  a = { type = 'string', transform = func_1 },
--                  b = { type = 'number', default = 1, transform = func_2 }
--              }
--          }
--      )
--      assert(full_object == { a = 'asd_1', b = 2 })
--
-- if the transformation function throws an error, the error will be stored
-- in `${.path.to}.problem.details.transform_error`
--
-- --
-- Composite type `table` (or `map`) can describe its elements by `.properties`
-- schema.
--
-- Example:
--      validator.check(
--          value,
--          {
--              type = 'table',
--              properties = {
--                  [1] = 'integer?',
--                  [2] = 'unsigned',
--                  abc = 'string'
--              }
--          }
--      )
--
--  There are some additional flags for type `table` (or `map`)
--
--  skip_unexpected_check -- if true, will not generate problem
--                           section about unexpected keys,
--  return_unexpected     -- if true, will return unexpected
--                           keys as is.
--
-- --
-- Composite type `array` can describe its elements by `.items` schema.
--
-- Example:
--      validator.check(
--          value,
--          {
--              type = 'array',
--              items = {
--                  type = 'integer',
--              }
--          }
--      )
-- --
-- Pseudo type `oneof`
--
-- The type allow check value that can be one of some different variants.
--
-- Example:
--      validator.check(
--          value,
--          {
--              type = 'oneof',
--              variants = {
--                 'string',
--                 'uuid',
--                 { 'unsigned', min = 1 },
--              }
--          }
--      )
--
--  Note: if one variant is fit, followed checks aren't touched.
--
--  Note: if no one variant is fit, the checker returns all found problems.
--
-- --
-- Additional constraints for elements:
--
-- - min -- minimum value
-- - max -- maximum value
-- - min_length -- minimum length of string or table value
-- - max_length -- maximum length of string of table value
--
-- Examples:
--      validator.check(
--          value,              -- value is non-empty string upto len=64
--          {
--              type = 'string',
--              min_length = 1,
--              max_length = 64,
--          }
--      )
--
--      validator.check(
--          value,              -- value is a number between 128 and 256
--          {
--              type = 'integer',
--              min_length = 128,
--              max_length = 256,
--          }
--      )
--
-- --
-- Additional constraint for elements: match
--
-- The constraints checks if the element can be matched as regexp.
--
-- Example:
--      validator.check(
--          value,
--          {
--              type = 'string',
--              match = '^H[%w%s,]+d$',
--          }
--      )
-- --
-- Custom constraints. A user can define its own functional constraints.
--
-- Example:
--      validator.check(
--          value,
--          {
--              type = 'unsigned',
--              -- check if value is even
--              constraint = function(value)
--                  if value % 2 ~= 0 then
--                      error("The value have to be even!")
--                  end
--              end
--          }
--      )
--
-- if the checker throws an error, the error will be stored
-- in `${.path.to}.problem.details.constraint_error`
--
-- --
-- SYNTAX SUGAR
--
-- Feel free to drop `type` in check description.
--
-- Example:
--      validator.check(value, { type = 'string' })
--      validator.check(value, { 'string' })        -- the same
--      validator.check(value, 'string')            -- the same
--
-- Also You can use short form for type and default.
--
-- Example:
--      validator.check(value, { type = 'number', default = 123 })
--      validator.check(value, { 'number', 123 })                   -- the same
-- --
-- Named validator
--
-- You can add `name` to each validator. The field will
-- translated (AS IS) to problem sections. It would be useful if You
-- validate through big flat array.
--
-- Example:
--      validator.check(value, { type = 'number', name = 'foobar' })


local luuid = require('uuid')
local ffi = require('ffi')

local int64_t = ffi.typeof(0LL)
local uint64_t = ffi.typeof(0ULL)

local type_checker = {
    uuid = function(obj)
        return luuid.is_uuid(obj)
    end,

    tuple = function(obj)
        return box.tuple.is(obj)
    end,

    integer = function(obj)
        local otype = type(obj)

        if otype == 'cdata' then
            local ctype = ffi.typeof(obj)

            if ctype == int64_t then
                return true
            end
            if ctype == uint64_t then
                return true
            end

            return false
        elseif otype ~= 'number' then
            return false
        end
        return obj % 1 == 0
    end,

    unsigned = function(obj)
        local otype = type(obj)

        if otype == 'cdata' then
            local ctype = ffi.typeof(obj)

            if ctype == uint64_t then
                return true
            end
            if ctype == int64_t then
                return obj >= 0
            end

            return false
        elseif otype ~= 'number' then
            return false
        end
        if obj % 1 ~= 0 then
            return false
        end

        return obj >= 0
    end,

    table = function(obj)
        return type(obj) == 'table'
    end,

    array = function(obj)
        return type(obj) == 'table'
    end,

    map = function(obj)
        return type(obj) == 'table'
    end,

    number = function(obj)
        local otype = type(obj)

        if otype == 'cdata' then
            local ctype = ffi.typeof(obj)

            if ctype == uint64_t then
                return true
            end
            if ctype == int64_t then
                return true
            end

            return false
        end
        return otype == 'number'
    end,

    string = function(obj)
        return type(obj) == 'string'
    end,

    boolean = function(obj)
        return type(obj) == 'boolean'
    end,

    null = function(obj)
        return obj == box.NULL
    end,

    -- is internal alias
    ['nil'] = function(obj)
        return type(obj) == 'nil'
    end,

    ['function'] = function(obj)
        if type(obj) == 'function' then
            return true
        end
        local mt = getmetatable(obj)

        if mt and type(mt.__call) == 'function' then
            return true
        end

        return false
    end,

    any = function()
        return true
    end,
}


local PROVIDED_TYPES = {}

for k in pairs(type_checker) do
    if k ~= 'nil' then
        table.insert(PROVIDED_TYPES, k)
    end
end
table.sort(PROVIDED_TYPES)

local function is_type(arg, arg_type)
    local checker = type_checker[arg_type]
    if not checker then
        return false
    end
    return checker(arg)
end

local function is_map_type(type_name)
    if type_name == 'table' then
        return true
    end
    if type_name == 'map' then
        return true
    end
    return false
end

local function path_join(path, element)

    if type(element) == 'string' and string.find(element, '^[_%l]') then
        return string.format('%s.%s', path, element)
    end

    -- dot notation only if the element is an identifier
    return string.format('%s[%d]', path, element)
end

local function collect_errors(arg, schema, opts, path, retval, errors)
    assert(type(retval) == 'table')
    assert(type(errors) == 'table')

    if type(schema) == 'string' then
        schema = { type = schema }
    end
    local actual_type = type(arg)
    local expected_type = schema.type or schema[1] or 'any'
    local optional = schema.optional or false

    if string.endswith(expected_type, '?') then
        optional = true
        expected_type = string.gsub(expected_type, '.$', '')
    end

    if arg == nil then
        local default = schema.default
        if default == nil then
            default = schema[2]
        end
        if not opts.disable_transformations and default ~= nil then
            arg = table.deepcopy(default)
        end
    end

    if arg == nil and expected_type ~= 'null' and expected_type ~= 'any' then
        if not optional then
            table.insert(errors,
                         {
                             path = path,
                             name = schema.name,
                             type = 'UNDEFINED_VALUE',
                             message = 'Undefined value',
                         })
        end
        goto exit
    end

    if expected_type == 'oneof' then
        if type(schema.variants) == 'table' then
            local found_errors = {}
            for _, variant in pairs(schema.variants) do
                    local new_errors = {}
                    local rv = {}
                    collect_errors(
                        arg,
                        variant,
                        opts,
                        path,
                        rv,
                        new_errors
                    )
                    -- oneof variant is fit
                    if #new_errors == 0 then
                        retval[1] = rv[1]
                        goto exit
                    end
                    for _, e in pairs(new_errors) do
                        table.insert(found_errors, e)
                    end
            end
            -- no fit variant found
            for _, e in pairs(found_errors) do
                table.insert(errors, e)
            end
        end

        table.insert(
            errors,
            {
                path = path,
                name = schema.name,
                type = 'ONEOF_ERROR',
                message = "The object isn't fit for any variant",
                details = {
                    value = arg,
                    oneof_schema = schema
                }
            }
        )
        goto exit
    end

    if not is_type(arg, expected_type) then
        local cdata_type
        if actual_type == 'cdata' then
            -- tostring for details to be serializable and comparable
            cdata_type = tostring(ffi.typeof(arg))
        end
        table.insert(
            errors,
            {
                path = path,
                name = schema.name,
                type = 'TYPE_ERROR',
                message = string.format(
                    'Wrong type, expected %s, got %s',
                    expected_type,
                    actual_type
                ),
                details = {
                         expected_type = expected_type,
                         actual_type = actual_type,
                         value = arg,
                         cdata_type = cdata_type,
                }
            }
        )

        -- additional checkers required properly set type,
        -- so skip them if type is wrong
        goto exit;
    end

    -- check if value > gt
    if schema.gt then
        local ok, res = pcall(function() return arg <= schema.gt end)

        if (not ok) or res then
            local err = 'Value is too small'
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = err:format(schema.gt),
                    details = {
                        gt = schema.gt,
                        value = arg,
                    }
                }
            )
        end
    end

    -- check if value < lt
    if schema.lt then
        local ok, res = pcall(function() return arg >= schema.lt end)

        if (not ok) or res then
            local err = 'Value is too big'
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = err:format(schema.lt),
                    details = {
                        lt = schema.lt,
                        value = arg,
                    }
                }
            )
        end
    end

    -- check if value >= minimum
    if schema.min then
        local ok, res = pcall(function() return arg < schema.min end)

        if (not ok) or res then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = 'Value is less than minimum',
                    details = {
                             min = schema.min,
                             value = arg,
                    }
                }
            )
        end
    end

    -- check if value <= maximum
    if schema.max then
        local ok, res = pcall(function() return  arg > schema.max end)

        if (not ok) or res then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = 'Value exceeded maximum',
                    details = {
                             max = schema.max,
                             value = arg,
                    }
                }
            )
        end
    end

    if schema.min_length then
        local ok, res = pcall(function() return #arg < schema.min_length end)

        if (not ok) or res then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = 'Value len is less than minimum',
                    details = {
                             min_len = schema.min_length,
                             value = arg,
                    }
                }
            )
        end
    end

    if schema.max_length then
        local ok, res = pcall(function() return #arg > schema.max_length end)

        if (not ok) or res then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = 'Value len exceeded maximum',
                    details = {
                             max_len = schema.max_length,
                             value = arg,
                    }
                }
            )
        end
    end

    if schema.match then
        if not string.find(tostring(arg), schema.match) then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = "Value doesn't match the regexp",
                    details = {
                             match_string = schema.match,
                             value = arg,
                    }
                }
            )
        end
    end

    if schema.enum then
        local list = schema.enum
        if type(list) ~= 'table' then
            list = { list }
        end

        local found = false
        for _, variant in pairs(list) do
            pcall(      -- no errors if enum contains non-comparable items
                function()
                    if arg == variant then
                        found = true
                    end
                end
            )
            if found then
                break
            end
        end

        if not found then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'VALUE_ERROR',
                    message = "Value does not belong to set",
                    details = {
                        enum_variants = table.deepcopy(list),
                        value = arg,
                    }
                }
            )
        end
    end

    -- check children
    if is_map_type(expected_type) then

        local result = {}
        local mt = getmetatable(arg)
        if mt ~= nil then
            setmetatable(result, mt)
        end
        local schema_rename = schema.rename
        local schema_properties = schema.properties

        local item_schema = schema.items
        if item_schema ~= nil then
            assert(schema_rename == nil)
            assert(schema_properties == nil)
            if type(item_schema) == 'string' then
                item_schema = {type = item_schema}
            end
            for key, item in pairs(arg) do
                local rv = {}
                collect_errors(
                    item,
                    item_schema,
                    opts,
                    path_join(path, key),
                    rv,
                    errors
                )
                result[key] = rv[1]
            end
            retval[1] = result
            goto exit
        end

        local map = arg
        if not opts.disable_transformations and schema_rename ~= nil then
            map = table.deepcopy(arg)
            assert(type(schema_rename) == 'table')
            for alias, name in pairs(schema_rename) do
                if arg[alias] ~= nil then
                    map[name] = map[alias]
                    map[alias] = nil
                end
            end
        end

        -- there is no schema of table, return it as is
        if schema_properties == nil then
            retval[1] = table.deepcopy(map)
            goto exit
        end

        assert(type(schema_properties) == 'table')

        local expected_keys = {}
        for subkey, subvalue in pairs(schema_properties) do
            expected_keys[subkey] = true
            local rv = {}
            collect_errors(
                map[subkey],
                subvalue,
                opts,
                path_join(path, subkey),
                rv,
                errors
            )
            result[subkey] = rv[1]
        end

        if schema.return_unexpected then
            for subkey, subvalue in pairs(map) do
                if not expected_keys[subkey] then
                    result[subkey] = subvalue
                end
            end
        elseif not schema.skip_unexpected_check then
            for subkey, _ in pairs(map) do
                if not expected_keys[subkey] then
                    table.insert(
                        errors,
                        {
                            path = path_join(path, subkey),
                            name = schema.name,
                            type = 'UNEXPECTED_KEY',
                            message = 'Unexpected key',
                            details = {
                                    unexpected_key = subkey,
                                    value = map,
                            }
                        }
                    )
                end
            end
        end
        retval[1] = result
        goto exit
    end

    if expected_type == 'array' then
        local result = {}
        local mt = getmetatable(arg)
        if mt ~= nil then
            setmetatable(result, mt)
        end

        local item_schema = schema.items or {}
        if type(item_schema) == 'string' then
            item_schema = { type = item_schema }
        end
        assert(type(item_schema) == 'table')

        local no = 0
        for index, item in pairs(arg) do
            no = no + 1

            if index == no then
                local rv = {}
                collect_errors(
                    item,
                    item_schema,
                    opts,
                    path_join(path, index),
                    rv,
                    errors
                )
                result[index] = rv[1]
            else
                table.insert(
                    errors,
                    {
                        path = path,
                        name = schema.name,
                        type = 'ARRAY_EXPECTED',
                        message = 'Unexpected map',
                        details = {
                            expected_index = no,
                            got_index = index,
                        }
                    }
                )
                break
            end
        end

        retval[1] = result
        goto exit
    end

    retval[1] = table.deepcopy(arg)

::exit::

    if #errors == 0 and schema.constraint ~= nil then
        local ok, err = pcall(schema.constraint, retval[1])
        if not ok then
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'CONSTRAINT_ERROR',
                    message = 'Field constraint detected error',
                    details = {
                        value = arg,
                        constraint_error = err,
                    }
                }
            )
        end
    end

    if #errors == 0 and schema.transform ~= nil and
                    not opts.disable_transformations then
        local ok, ret = pcall(schema.transform, retval[1])
        if not ok then
            local err = ret
            table.insert(
                errors,
                {
                    path = path,
                    name = schema.name,
                    type = 'TRANSFORM_ERROR',
                    message = 'Field transformation failed',
                    details = {
                        value = arg,
                        transform_error = err,
                    }
                }
            )
        else
            retval[1] = ret
        end
    end

    if #errors > 0 then
        retval[1] = nil
    end
end


-- exported function
--
-- description is at the top of the file

local function check(arg, schema, opts)
    local errors = {}
    local retval = {}
    collect_errors(arg, schema, opts or {}, '$', retval, errors)
    return retval[1], errors
end


return {
    check           = check,
    PROVIDED_TYPES  = PROVIDED_TYPES
}
