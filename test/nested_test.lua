#!/usr/bin/env tarantool
-- Tests for deeply nested schemas: transform, rename,
-- constraint at every level (map -> array -> map).

local t  = require('luatest')
local cv = require('cv')

local g = t.group('nested')

-- -------------------------------------------------------
-- Schema: map -> array -> map (three levels deep)
-- -------------------------------------------------------
--
-- top:  map  with transform + constraint
--   items: array with transform + constraint
--     item: map with rename + transform + constraint

local function make_schema()
    return {
        type = 'map',
        properties = {
            rows = {
                type = 'array',
                constraint = function(v)
                    if #v == 0 then
                        error("rows must not be empty",
                            0)
                    end
                end,
                transform = function(v)
                    -- mark array as processed
                    v._processed = true
                    return v
                end,
                items = {
                    type = 'map',
                    -- rename numeric keys to names
                    rename = {[1] = 'id', [2] = 'val'},
                    constraint = function(v)
                        if v.id ~= nil and
                           v.id <= 0 then
                            error("id must be > 0",
                                0)
                        end
                    end,
                    transform = function(v)
                        v.tag = 'ok'
                        return v
                    end,
                },
            },
        },
        transform = function(v)
            v.top_seen = true
            return v
        end,
    }
end

-- -------------------------------------------------------
-- rename: numeric keys renamed to string keys
-- -------------------------------------------------------
function g.test_nested_rename()
    -- mix: numeric keys (need rename) and
    -- string keys (already correct, no rename)
    local r, e = cv.check(
        {rows = {
            {1, 'hello'},         -- rename needed
            {id = 2, val = 'hi'}, -- already named
            {3, 'world'},         -- rename needed
            {id = 4, val = 'ok'}, -- already named
        }},
        make_schema()
    )
    t.assert_equals(e, {})
    -- rows[1]: numeric keys renamed
    t.assert_equals(r.rows[1].id,  1)
    t.assert_equals(r.rows[1].val, 'hello')
    t.assert_equals(r.rows[1][1],  nil)
    t.assert_equals(r.rows[1][2],  nil)
    -- rows[2]: already named, no change
    t.assert_equals(r.rows[2].id,  2)
    t.assert_equals(r.rows[2].val, 'hi')
    -- rows[3]: numeric keys renamed
    t.assert_equals(r.rows[3].id,  3)
    t.assert_equals(r.rows[3].val, 'world')
    t.assert_equals(r.rows[3][1],  nil)
    t.assert_equals(r.rows[3][2],  nil)
    -- rows[4]: already named, no change
    t.assert_equals(r.rows[4].id,  4)
    t.assert_equals(r.rows[4].val, 'ok')
end

-- -------------------------------------------------------
-- transform: applied at every level
-- -------------------------------------------------------
function g.test_nested_transform()
    local r, e = cv.check(
        {rows = {{1, 'x'}}},
        make_schema()
    )
    t.assert_equals(e, {})
    -- item-level transform: tag = 'ok'
    t.assert_equals(r.rows[1].tag, 'ok')
    -- array-level transform: _processed = true
    t.assert_equals(r.rows._processed, true)
    -- top-level transform: top_seen = true
    t.assert_equals(r.top_seen, true)
end

-- -------------------------------------------------------
-- constraint: fires at correct level
-- -------------------------------------------------------
function g.test_nested_constraint_array()
    -- empty rows violates array constraint
    local r, e = cv.check(
        {rows = {}},
        make_schema()
    )
    t.assert_equals(r, nil)
    t.assert_equals(#e, 1)
    t.assert_equals(e[1].type, 'CONSTRAINT_ERROR')
    t.assert_equals(e[1].path, '$.rows')
end

function g.test_nested_constraint_item()
    -- id <= 0 violates item constraint
    local r, e = cv.check(
        {rows = {{0, 'x'}}},
        make_schema()
    )
    t.assert_equals(r, nil)
    t.assert_equals(#e, 1)
    t.assert_equals(e[1].type, 'CONSTRAINT_ERROR')
    t.assert_equals(e[1].path, '$.rows[1]')
end

-- -------------------------------------------------------
-- combined: rename + transform + constraint all pass
-- -------------------------------------------------------
function g.test_nested_combined()
    local r, e = cv.check(
        {rows = {{1, 'a'}, {2, 'b'}}},
        make_schema()
    )
    t.assert_equals(e, {})
    -- rename
    t.assert_equals(r.rows[1].id,  1)
    t.assert_equals(r.rows[2].id,  2)
    -- item transform
    t.assert_equals(r.rows[1].tag, 'ok')
    t.assert_equals(r.rows[2].tag, 'ok')
    -- array transform
    t.assert_equals(r.rows._processed, true)
    -- top transform
    t.assert_equals(r.top_seen, true)
end

-- vim: ts=4 sts=4 sw=4 et
