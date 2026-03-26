-- cv — fast schema validator for Tarantool
--
-- API:
--   cv.compile(def [, opts]) -> schema, errors
--     opts: { raise_errors = bool }
--
--   cv.check(data, schema_def [, opts]) -> data, errors
--     schema_def: string | table | compiled schema
--     opts: { validate_only = bool,
--             raise_errors  = bool }
--
--   cv.is_schema(v) -> bool
--
--   schema:check(data [, opts]) -> data, errors
--   schema:totable([format]) -> table
--     format: 'tarantool' (default) | 'openapi'
--
-- On success: data is the (possibly mutated) value,
--             errors is an empty table {}.
-- On failure: data is nil,
--             errors is a list of error objects.
--
-- Each error object:
--   { path    = '$.field.name',
--     type    = 'TYPE_ERROR' | 'VALUE_ERROR' | ...,
--     message = 'human readable description',
--     details = { ... },   -- always present
--     name    = 'field',   -- optional, from schema
--   }

local ffi  = require('ffi')
local uuid = require('uuid')

local _cv = require('cv.cvalidator')

-- Initialize C runtime with type handles.
-- Called once at module load time.
_cv._init({
    uuid_is     = uuid.is_uuid,
    tuple_is    = box.tuple.is,
    ffi_typestr = function(v)
        return tostring(ffi.typeof(v))
    end,
    box_null    = box.NULL,
    deepcopy    = table.deepcopy,
})

-- -------------------------------------------------------
-- Public module table
-- -------------------------------------------------------

local M = {}

-- -------------------------------------------------------
-- M.compile(def [, opts]) -> schema, errors
-- -------------------------------------------------------

function M.compile(def, opts)
    return _cv.compile(def, opts)
end

-- -------------------------------------------------------
-- M.is_schema(v) -> bool
-- -------------------------------------------------------

function M.is_schema(v)
    return _cv.is_schema(v)
end

-- -------------------------------------------------------
-- M.check(data, schema_def [, opts]) -> data, errors
--
-- Compatible with old validator.check API.
-- schema_def may be already compiled schema.
-- -------------------------------------------------------

function M.check(data, schema_def, opts)
    local s
    if _cv.is_schema(schema_def) then
        s = schema_def
    else
        local errs
        s, errs = _cv.compile(schema_def)
        if s == nil then
            return nil, errs
        end
    end
    return s:check(data, opts or {})
end

-- -------------------------------------------------------
-- PROVIDED_TYPES — list of supported type names
-- (compatible with old validator)
-- -------------------------------------------------------

M.PROVIDED_TYPES = {
    'boolean',
    'string',
    'number',
    'integer',
    'unsigned',
    'table',
    'map',
    'array',
    'uuid',
    'tuple',
    'nil',
    'any',
    'function',
    'oneof',
}

return M
-- vim: ts=4 sts=4 sw=4 et
