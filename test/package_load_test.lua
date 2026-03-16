#!/usr/bin/env tarantool

local t = require('luatest')
local g = t.group('cv')

g.test_load = function()
    local cv = require('cv')
    t.assert_type(cv, 'table', 'cv module is a table')
end
-- vim: ts=4 sts=4 sw=4 et
