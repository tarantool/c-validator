#!/usr/bin/env tarantool

local t = require('luatest')
local server = require('luatest.server')
local g = t.group('cv')

g.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {app_threads = 1},
        net_box_credentials = {user = 'admin'}
    })
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_threads = function(cg)
    local function check()
        local cv = require('cv')
        local uuid = require('uuid')
        local result, problems = cv.check({
            int64 = -123LL,
            uint64 = 42LL,
            tuple = box.tuple.new({123}),
            uuid = uuid.NULL,
            null = box.NULL,
            nested = {},
        }, {
            type = 'table',
            properties = {
                int64 = {'integer'},
                uint64 = {'unsigned'},
                tuple = 'tuple',
                uuid = 'uuid',
                null = 'null',
                nested = {
                    type = 'table',
                    properties = {
                        foo = {'boolean', default = true},
                    },
                },
            },
        })
        t.assert_equals(problems, {})
        t.assert_equals(result, {
            int64 = -123LL,
            uint64 = 42LL,
            tuple = box.tuple.new({123}),
            uuid = uuid.NULL,
            null = box.NULL,
            nested = {foo = true},
        })
        result, problems = cv.check(box.tuple.new({123}), 'uuid')
        t.assert_is(result, nil)
        t.assert_equals(problems, {
            {
                type = 'TYPE_ERROR',
                message = 'Wrong type, expected uuid, got cdata',
                path = '$',
                details = {
                    value = box.tuple.new({123}),
                    actual_type = 'cdata',
                    cdata_type = 'ctype<struct tuple &>',
                    expected_type = 'uuid',
                },
            },
        })
    end
    cg.server:exec(check, {}, {_thread_id = 0})
    cg.server:exec(check, {}, {_thread_id = 1})
    cg.server:exec(check, {}, {_thread_id = 0})
    cg.server:exec(check, {}, {_thread_id = 1})
end
-- vim: ts=4 sts=4 sw=4 et
