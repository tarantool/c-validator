#!/usr/bin/env tarantool
-- Tests that default table values are deepcopied on each
-- check() call, not shared by reference.

local t  = require('luatest')
local cv = require('cv')

local g = t.group('inplace_default_deepcopy')

-- Top-level default={} must be deepcopied: mutating the
-- returned value must not affect the next check() call,
-- and the original default variable must stay untouched.
function g.test_toplevel_default_deepcopy()
    local top_default = {}
    local s = cv.compile({
        type = 'map',
        default = top_default,
        properties = {
            x = {type = 'number', default = 10},
        },
    })

    local r1, e1 = s:check(nil)
    t.assert_equals(e1, {})
    t.assert_equals(r1.x, 10)

    -- mutate the result in place
    r1.x = 999

    -- original default variable must stay empty
    t.assert_equals(top_default, {})

    -- second call must return a fresh copy
    local r2, e2 = s:check(nil)
    t.assert_equals(e2, {})
    t.assert_equals(r2.x, 10)
end

-- Field-level default={} must be deepcopied: mutating the
-- returned nested map must not affect the next check() call,
-- and the original default variable must stay untouched.
function g.test_field_default_deepcopy()
    local opts_default = {}
    local s = cv.compile({
        type = 'map',
        properties = {
            opts = {
                type = 'map',
                default = opts_default,
                properties = {
                    retries = {
                        type = 'number',
                        default = 3,
                    },
                },
            },
        },
    })

    local r1, e1 = s:check({})
    t.assert_equals(e1, {})
    t.assert_equals(r1.opts.retries, 3)

    -- mutate the result in place
    r1.opts.retries = 999

    -- original default variable must stay empty
    t.assert_equals(opts_default, {})

    -- second call must return a fresh copy
    local r2, e2 = s:check({})
    t.assert_equals(e2, {})
    t.assert_equals(r2.opts.retries, 3)
end

-- vim: ts=4 sts=4 sw=4 et
