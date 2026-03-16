#!/usr/bin/env tarantool
--
-- Benchmark: old Lua validator vs new cv (C) validator
--

local old = require('validator')
local cv  = require('cv')

-- -------------------------------------------------------
-- Schema definition
-- -------------------------------------------------------

local schema_def = {
    type = 'map',
    properties = {
        id       = 'unsigned',
        name     = 'string',
        email    = { type = 'string', match = '^[^@]+@[^@]+$' },
        age      = { type = 'integer', min = 0, max = 150 },
        score    = { type = 'number',  min = 0.0, max = 1.0 },
        active   = 'boolean',
        tags     = {
            type  = 'array',
            items = 'string',
        },
        address  = {
            type = 'map',
            properties = {
                city    = 'string',
                country = 'string',
                zip     = { type = 'string', min_length = 4,
                            max_length = 10 },
            },
        },
        scores   = {
            type  = 'array',
            items = { type = 'number', min = 0, max = 100 },
        },
        meta     = {
            type = 'map',
            properties = {
                source  = 'string',
                version = 'unsigned',
            },
        },
    },
}

-- -------------------------------------------------------
-- Test data
-- -------------------------------------------------------

local data_template = {
    id     = 42,
    name   = 'Alice',
    email  = 'alice@example.com',
    age    = 30,
    score  = 0.95,
    active = true,
    tags   = { 'lua', 'tarantool', 'cv' },
    address = {
        city    = 'Moscow',
        country = 'Russia',
        zip     = '101000',
    },
    scores = { 95.5, 87.0, 100.0, 72.3 },
    meta   = {
        source  = 'api',
        version = 3,
    },
}

-- deepcopy to avoid mutations between iterations
local function deepcopy(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k, v in pairs(t) do
        r[k] = deepcopy(v)
    end
    return r
end

-- -------------------------------------------------------
-- Compile new schema once
-- -------------------------------------------------------

local schema, err = cv.compile(schema_def)
assert(schema ~= nil,
    'cv.compile failed: ' .. tostring(
        err and err[1] and err[1].message or '?'))

-- -------------------------------------------------------
-- Sanity check: both validators agree on valid data
-- -------------------------------------------------------

local old_result, old_errs = old.check(
    deepcopy(data_template), schema_def)
assert(#old_errs == 0,
    'old validator errors: ' ..
    tostring(old_errs[1] and old_errs[1].message))

local new_ok, new_errs = schema:check(
    deepcopy(data_template))
assert(new_ok,
    'new validator errors: ' ..
    tostring(new_errs[1] and new_errs[1].message))

print('Sanity check passed: both validators OK')
print()

-- -------------------------------------------------------
-- Benchmark helper
-- -------------------------------------------------------

local function bench(label, n, fn)
    -- warmup
    for _ = 1, 100 do fn() end

    local t0 = os.clock()
    for _ = 1, n do fn() end
    local t1 = os.clock()

    local elapsed = t1 - t0
    local per_call = elapsed / n * 1e6  -- microseconds
    print(string.format('%-20s  %7d calls  %8.3f ms total'
        .. '  %7.3f us/call',
        label, n, elapsed * 1000, per_call))
end

local N = 50000

-- -------------------------------------------------------
-- Baseline: deepcopy alone
-- -------------------------------------------------------

bench('deepcopy only', N, function()
    deepcopy(data_template)
end)

-- -------------------------------------------------------
-- Old validator bench (Lua)
-- -------------------------------------------------------

bench('old (Lua)', N, function()
    old.check(deepcopy(data_template), schema_def)
end)

-- -------------------------------------------------------
-- New validator bench (C, validate_only=false)
-- -------------------------------------------------------

bench('new cv:check', N, function()
    schema:check(deepcopy(data_template))
end)

-- -------------------------------------------------------
-- New validator bench (validate_only=true)
-- -------------------------------------------------------

bench('new cv:check v_only', N, function()
    schema:check(deepcopy(data_template),
        { validate_only = true })
end)

-- -------------------------------------------------------
-- New validator: validate_only without deepcopy
-- (pure validation cost, no data mutation)
-- -------------------------------------------------------

bench('new cv v_only no copy', N, function()
    schema:check(data_template,
        { validate_only = true })
end)

print()
print('Done.')
