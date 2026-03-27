#!/usr/bin/env tarantool
-- Compatibility test: new cv module vs old validator API
-- Adapted from aeon/test/common/validator_test.lua

local t  = require('luatest')
local cv = require('cv')

local luuid = require('uuid')

local g = t.group('compat')

function g.test_common()
    t.assert_equals(
        { cv.check(nil, 'null') },
        { nil, {} }
    )

    t.assert_equals(
        { cv.check(nil, 'any') },
        { nil, {} }
    )

    t.assert_equals(
        { cv.check(box.NULL, 'null') },
        { nil, {} }
    )

    t.assert_equals(
        { cv.check(box.NULL, 'any') },
        { nil, {} }
    )

    -- optional tests
    for _, variant in pairs(cv.PROVIDED_TYPES) do
        local r, e = cv.check(nil, variant .. '?')
        t.assert_equals(r, nil,
            'optional ' .. variant ..
            ' should accept nil')
        t.assert_equals(#e, 0,
            'optional ' .. variant ..
            ' should have no errors')
    end

    -- uuid
    local uuid = luuid.new()
    t.assert_covers(
        { cv.check(uuid, 'uuid?') },
        { uuid, {} }
    )

    for _, uvalue in pairs{1LL, 0LL, 121LL, 1, 2, 3} do
        t.assert_covers(
            { cv.check(uvalue, 'unsigned?') },
            { uvalue, {} }
        )
    end

    for _, uvalue in pairs{-1LL, 0LL, -121LL, 1, -2, 3}
    do
        t.assert_covers(
            { cv.check(uvalue, 'integer?') },
            { uvalue, {} }
        )
    end

    t.assert_equals(
        { cv.check(1, { type = 'number' }) },
        { 1, {} }
    )
    t.assert_equals(
        { cv.check(1, { 'number' }) },
        { 1, {} }
    )
    t.assert_equals(
        { cv.check(1, 'number') },
        { 1, {} }
    )
end

-- Regression: nil value for required field must produce
-- UNDEFINED_VALUE, not TYPE_ERROR (matches old validator).
function g.test_undefined_value()
    -- top-level nil without default
    local r, e = cv.check(nil, 'string')
    t.assert_equals(r, nil)
    t.assert_equals(#e, 1)
    t.assert_equals(e[1].type, 'UNDEFINED_VALUE')

    -- nil field in map without default
    local r2, e2 = cv.check(
        {x = nil},
        {
            type = 'map',
            properties = { x = 'number' },
        }
    )
    t.assert_equals(r2, nil)
    t.assert_equals(#e2, 1)
    t.assert_equals(e2[1].type, 'UNDEFINED_VALUE')
    t.assert_equals(e2[1].path, '$.x')

    -- nil is ok for optional field
    local r3, e3 = cv.check(
        {},
        {
            type = 'map',
            properties = { x = 'number?' },
        }
    )
    t.assert_equals(e3, {})
    t.assert_equals(r3, {})
end

-- nil value must NOT produce UNDEFINED_VALUE
-- when the field has a default.
function g.test_no_undefined_when_default()
    -- top-level nil with default
    local r, e = cv.check(nil,
        {type = 'string', default = 'hello'})
    t.assert_equals(e, {})
    t.assert_equals(r, 'hello')

    -- nil field in map with default
    local r2, e2 = cv.check(
        {},
        {
            type = 'map',
            properties = {
                x = {type = 'number', default = 42},
            },
        }
    )
    t.assert_equals(e2, {})
    t.assert_equals(r2.x, 42)

    -- nil field in map with default = false
    -- (falsy default must also work)
    local r3, e3 = cv.check(
        {},
        {
            type = 'map',
            properties = {
                flag = {
                    type = 'boolean',
                    default = false,
                },
            },
        }
    )
    t.assert_equals(e3, {})
    t.assert_equals(r3.flag, false)
end

function g.test_tables()
    for _, T in pairs{'table', 'map'} do
        local r, e = cv.check(
            { c = 'd', b = 123 },
            {
                type = T,
                properties = {
                    a = 'string?',
                    b = 'unsigned',
                    c = 'string',
                },
            }
        )
        t.assert_equals(e, {})
        t.assert_equals(r, { c = 'd', b = 123 })
    end
end

function g.test_skip_unexpected_check()
    for _, T in pairs{'table', 'map'} do
        local r, e = cv.check(
            { c = 'd', b = 123 },
            {
                type = T,
                properties = {
                    a = 'string?',
                },
                skip_unexpected_check = true,
            }
        )
        t.assert_equals(e, {})
        t.assert_equals(r, {})
    end

    for _, T in pairs{'table', 'map'} do
        local r, e = cv.check(
            { c = 'd', b = 123 },
            {
                type = T,
                properties = {
                    a = 'string?',
                },
                skip_unexpected_check = true,
                return_unexpected = true,
            }
        )
        t.assert_equals(e, {})
        t.assert_equals(r, { c = 'd', b = 123 })
    end
end

function g.test_defaults()
    t.assert_equals(
        { cv.check(nil,
            { type = 'number', default = 121 }) },
        { 121, {} }
    )
    t.assert_equals(
        { cv.check(nil,
            { type = 'integer', default = 121123 }) },
        { 121123, {} }
    )
    t.assert_equals(
        { cv.check(nil,
            { type = 'boolean', default = true }) },
        { true, {} }
    )
    t.assert_equals(
        { cv.check(nil,
            { type = 'boolean', default = false }) },
        { false, {} }
    )

    t.assert_equals(
        {
            cv.check(
                {},
                {
                    type = 'map',
                    properties = {
                        a = {
                            type = 'string',
                            default = 'Hello, world',
                        },
                        b = 'number?',
                        c = {
                            type = 'boolean',
                            default = false,
                        }
                    }
                }
            )
        },
        { { a = "Hello, world", c = false }, {} }
    )

    t.assert_equals(
        {
            cv.check(
                nil,
                {
                    type = 'map',
                    default = {},
                    properties = {
                        a = {type='string',
                             default='Hello, world'},
                        b = 'number?',
                        c = {type='boolean',
                             default=false}
                    },
                }
            )
        },
        {{ a = "Hello, world", c = false}, {}}
    )

    -- short forms
    t.assert_equals(
        { cv.check(nil,
            { 'number', default = 121 }) },
        { 121, {} }
    )
    t.assert_equals(
        { cv.check(nil, { 'number', 121 }) },
        { 121, {} }
    )
    t.assert_equals(
        {cv.check(nil,
            {type='number', default=121, min=1000})},
        {
            nil,
            {
                {
                    details = {min = 1000, value = 121},
                    message = "Value is less than minimum",
                    path = "$",
                    type = "VALUE_ERROR",
                },
            },
        }
    )
end

-- Regression: empty table passed as arg, field has
-- scalar default — deepcopy must not corrupt the stack.
function g.test_scalar_default_in_map()
    -- exact scenario from bug report:
    -- ARG={}, SCHEMA={type=map, ttl={number,default=5}}
    t.assert_equals(
        {
            cv.check(
                {},
                {
                    type = 'map',
                    properties = {
                        ttl = {
                            'number',
                            min = 0,
                            default = 5,
                        },
                    },
                }
            )
        },
        { {ttl = 5}, {} }
    )

    -- same but called twice in a row (stack leak check)
    local s = cv.compile({
        type = 'map',
        properties = {
            ttl = {type = 'number', default = 5},
            name = {type = 'string', default = 'x'},
        },
    })
    local r1, e1 = s:check({})
    t.assert_equals(e1, {})
    t.assert_equals(r1, {ttl = 5, name = 'x'})

    local r2, e2 = s:check({})
    t.assert_equals(e2, {})
    t.assert_equals(r2, {ttl = 5, name = 'x'})
end

function g.test_match()
    t.assert_equals(
        { cv.check('Hello, world',
            { 'string', match = 'llo%S' }) },
        { 'Hello, world', {} }
    )

    t.assert_equals(
        { cv.check('Hello',
            { 'string', match = 'abc' }) },
        {
            nil,
            {
                {
                    type = 'VALUE_ERROR',
                    details = {
                        match_string = 'abc',
                        value = 'Hello'
                    },
                    message = "Value doesn't match"
                              .. " the regexp",
                    path = '$',
                }
            }
        }
    )
end

function g.test_enum()
    t.assert_equals(
        { cv.check('11',
            { 'string', enum = {'12','11','10'} }) },
        { '11', {} }
    )

    t.assert_equals(
        { cv.check('11',
            { 'string', enum = {12, 11, 10} }) },
        {
            nil,
            {
                {
                    type = 'VALUE_ERROR',
                    details = {
                        enum_variants = {12, 11, 10},
                        value = '11'
                    },
                    message =
                        "Value does not belong to set",
                    path = '$',
                }
            }
        }
    )
end

function g.test_min_max()
    t.assert_equals(
        { cv.check(11,
            {'number', min = 11, max = 11}) },
        { 11, {} }
    )

    t.assert_equals(
        { cv.check(11LL,
            {'number', min = 11, max = 11}) },
        { 11LL, {} }
    )

    t.assert_equals(
        { cv.check(25,
            {'number', min = 11, max = 15}) },
        {
            nil,
            {
                {
                    type = "VALUE_ERROR",
                    details = {max = 15, value = 25},
                    message = "Value exceeded maximum",
                    path = "$",
                },
            }
        }
    )

    t.assert_equals(
        { cv.check(5,
            {'number', min = 11, max = 15}) },
        {
            nil,
            {
                {
                    type = "VALUE_ERROR",
                    details = {min = 11, value = 5},
                    message =
                        "Value is less than minimum",
                    path = "$",
                },
            }
        }
    )
end

function g.test_gt()
    t.assert_equals(
        {cv.check(11, {'number', gt = 10})},
        {11, {}}
    )
    t.assert_equals(
        {cv.check(11LL, {'number', gt = 10})},
        {11LL, {}}
    )
    t.assert_equals(
        {cv.check(11, {'number', gt = 11})},
        {
            nil,
            {
                {
                    type = "VALUE_ERROR",
                    details = {gt = 11, value = 11},
                    message = "Value is too small",
                    path = "$",
                },
            }
        }
    )
end

function g.test_lt()
    t.assert_equals(
        {cv.check(9, {'number', lt = 10})},
        {9, {}}
    )
    t.assert_equals(
        {cv.check(9LL, {'number', lt = 10})},
        {9LL, {}}
    )
    t.assert_equals(
        {cv.check(11, {'number', lt = 11})},
        {
            nil,
            {
                {
                    type = "VALUE_ERROR",
                    details = {lt = 11, value = 11},
                    message = "Value is too big",
                    path = "$",
                },
            }
        }
    )
end

function g.test_min_max_length()
    t.assert_equals(
        { cv.check('x',
            {'string', min_length=0, max_length=3}) },
        { 'x', {} }
    )

    t.assert_equals(
        { cv.check({'x'},
            {'array', min_length=0, max_length=3}) },
        { {'x'}, {} }
    )

    t.assert_equals(
        { cv.check('xxxx',
            {'string', min_length=0, max_length=3}) },
        {
            nil,
            {
                {
                    type = 'VALUE_ERROR',
                    path = '$',
                    message = 'Value len exceeded maximum',
                    details = {
                        max_len = 3,
                        value = "xxxx",
                    }
                }
            }
        }
    )

    t.assert_equals(
        { cv.check({1, 2},
            {'array', min_length = 3}) },
        {
            nil,
            {
                {
                    type = 'VALUE_ERROR',
                    path = '$',
                    message =
                        'Value len is less than minimum',
                    details = {
                        min_len = 3,
                        value = { 1, 2 },
                    }
                }
            }
        }
    )
end

function g.test_arrays()
    t.assert_equals(
        { cv.check({'x'}, { type = 'array' }) },
        { {'x'}, {} }
    )
    t.assert_equals(
        { cv.check({'x'}, { 'array' }) },
        { {'x'}, {} }
    )
    t.assert_equals(
        { cv.check({'x'},
            { 'array', items = { 'string' } }) },
        { {'x'}, {} }
    )
    t.assert_equals(
        { cv.check({'x'},
            { 'array', items = 'string' }) },
        { {'x'}, {} }
    )

    t.assert_equals(
        { cv.check({'x'},
            { 'array', items = { 'number' } }) },
        {
            nil,
            {
                {
                    type = "TYPE_ERROR",
                    details = {
                        actual_type = "string",
                        expected_type = "number",
                        value = "x"
                    },
                    message =
                        "Wrong type, expected"
                        .. " number, got string",
                    path = "$[1]",
                },
            }
        }
    )

    local ary = {}
    ary[1] = 1
    ary[2] = box.NULL
    ary[3] = 3

    t.assert_equals(
        { cv.check(ary,
            { 'array', items = { 'number?' } }) },
        { {1, nil, 3}, {} }
    )
end

function g.test_uuid()
    local uuid = luuid.new()
    t.assert_equals(
        { cv.check(uuid, 'uuid') },
        { uuid, {} }
    )

    t.assert_equals(
        { cv.check(1LL, 'uuid') },
        {
            nil,
            {
                {
                    type = "TYPE_ERROR",
                    details = {
                        actual_type = "cdata",
                        cdata_type = 'ctype<int64_t>',
                        expected_type = "uuid",
                        value = 1LL,
                    },
                    message =
                        "Wrong type, expected"
                        .. " uuid, got cdata",
                    path = "$",
                },
            }
        }
    )
end

function g.test_tuple()
    local tuple = box.tuple.new({1, 2, 3})
    t.assert_equals(
        { cv.check(tuple, 'tuple') },
        { tuple, {} }
    )

    t.assert_equals(
        { cv.check(1LL, 'tuple') },
        {
            nil,
            {
                {
                    type = 'TYPE_ERROR',
                    details = {
                        actual_type = 'cdata',
                        cdata_type = 'ctype<int64_t>',
                        expected_type = 'tuple',
                        value = 1LL,
                    },
                    message =
                        'Wrong type, expected'
                        .. ' tuple, got cdata',
                    path = '$',
                },
            }
        }
    )
end

function g.test_name()
    t.assert_equals(
        { cv.check(1LL,
            { 'uuid', name = 'foobar'}) },
        {
            nil,
            {
                {
                   details = {
                       actual_type = "cdata",
                       cdata_type = "ctype<int64_t>",
                       expected_type = "uuid",
                       value = 1LL,
                   },
                   message =
                       "Wrong type, expected"
                       .. " uuid, got cdata",
                   path = "$",
                   type = "TYPE_ERROR",
                   name = 'foobar',
                },
            },
        }
    )
end

function g.test_fun()
    local f = function() return 1 end
    local fo = setmetatable({}, {__call = f})

    t.assert_equals(
        { cv.check(f, 'function') },
        { f, {} }
    )
    t.assert_equals(
        { cv.check(fo, 'function') },
        { fo, {} }
    )
    t.assert_equals(
        { cv.check(123, 'function') },
        {
            nil,
            {
                {
                    details = {
                        actual_type = "number",
                        expected_type = "function",
                        value = 123
                    },
                    message =
                        "Wrong type, expected"
                        .. " function, got number",
                    path = "$",
                    type = "TYPE_ERROR",
                },
            }
        }
    )
end

function g.test_func_constraint()
    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'number',
                    constraint = function(value)
                        t.assert_equals(value, 123)
                    end
                }
            )
        },
        { 123, {} }
    )

    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'number',
                    constraint = function(value)
                        t.assert_equals(value, 123)
                        error(false, 0)
                    end
                }
            )
        },
        {
            nil,
            {
                {
                    details = {
                        constraint_error = false,
                        value = 123
                    },
                    message =
                        "Field constraint detected"
                        .. " error",
                    path = "$",
                    type = "CONSTRAINT_ERROR",
                },
            }
        }
    )

    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'number',
                    constraint = function(value)
                        t.assert_equals(value, 123)
                        error("Hello, world", 0)
                    end
                }
            )
        },
        {
            nil,
            {
                {
                    message =
                        "Field constraint detected"
                        .. " error",
                    path = "$",
                    type = "CONSTRAINT_ERROR",
                    details = {
                        constraint_error =
                            "Hello, world",
                        value = 123,
                    }
                }
            }
        }
    )
end

function g.test_map_constraint()
    -- constraint ok
    t.assert_equals(
        {
            cv.check(
                {asd = 123},
                {
                    type = 'map',
                    properties = { asd = 'number' },
                    constraint = function(value)
                        t.assert_equals(
                            value, {asd = 123})
                    end
                }
            )
        },
        { {asd = 123}, {} }
    )

    -- constraint error (false)
    t.assert_equals(
        {
            cv.check(
                {asd = 123},
                {
                    type = 'map',
                    properties = { asd = 'number' },
                    constraint = function(_value)
                        error(false, 0)
                    end
                }
            )
        },
        {
            nil,
            {
                {
                    details = {
                        constraint_error = false,
                        value = {asd = 123},
                    },
                    message =
                        "Field constraint detected"
                        .. " error",
                    path = "$",
                    type = "CONSTRAINT_ERROR",
                },
            }
        }
    )
end

function g.test_array_constraint()
    -- constraint ok
    t.assert_equals(
        {
            cv.check(
                {1, 2, 3},
                {
                    type = 'array',
                    constraint = function(value)
                        t.assert_equals(
                            value, {1, 2, 3})
                    end
                }
            )
        },
        { {1, 2, 3}, {} }
    )

    -- constraint error (string)
    t.assert_equals(
        {
            cv.check(
                {1, 2, 3},
                {
                    type = 'array',
                    constraint = function(_value)
                        error("bad array", 0)
                    end
                }
            )
        },
        {
            nil,
            {
                {
                    details = {
                        constraint_error = "bad array",
                        value = {1, 2, 3},
                    },
                    message =
                        "Field constraint detected"
                        .. " error",
                    path = "$",
                    type = "CONSTRAINT_ERROR",
                },
            }
        }
    )
end

function g.test_nested_map_constraint()
    local schema = {
        type = 'map',
        properties = {
            -- outer has no constraint
            inner = {
                type = 'map',
                properties = {
                    x = 'number',
                },
                constraint = function(value)
                    if value.x > 3 then
                        error("x too big", 0)
                    end
                end,
            },
        },
    }

    -- constraint passes: x <= 3
    local r, e = cv.check(
        {inner = {x = 2}}, schema)
    t.assert_equals(e, {})
    t.assert_equals(r, {inner = {x = 2}})

    -- constraint fails: x > 3
    local r2, e2 = cv.check(
        {inner = {x = 5}}, schema)
    t.assert_equals(r2, nil)
    t.assert_equals(#e2, 1)
    t.assert_equals(e2[1].type, 'CONSTRAINT_ERROR')
    t.assert_equals(e2[1].path, '$.inner')
    t.assert_equals(
        e2[1].details.constraint_error, "x too big")
    t.assert_equals(
        e2[1].details.value, {x = 5})
end

function g.test_oneof()
    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'oneof',
                    variants = { 'string', 'number' }
                }
            )
        },
        { 123, {} }
    )

    -- oneof fail: errors from all variants + ONEOF_ERROR
    local r, e = cv.check(
        123,
        {
            'oneof',
            variants = { 'string', 'table' }
        }
    )
    t.assert_equals(r, nil)
    t.assert_equals(e[#e].type, 'ONEOF_ERROR')
    t.assert_equals(e[#e].details.value, 123)
    t.assert_is_not(
        e[#e].details.oneof_schema, nil)
    -- variant errors come first
    t.assert_equals(e[1].type, 'TYPE_ERROR')
end

function g.test_func_transform()
    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'number',
                    transform = function(value)
                        return value + 100
                    end
                }
            )
        },
        { 223, {} }
    )

    t.assert_equals(
        {
            cv.check(
                nil,
                {
                    'number',
                    default = 123,
                    transform = function(value)
                        return value * 2
                    end
                }
            )
        },
        { 246, {} }
    )

    -- transform returns nil → result is nil
    t.assert_equals(
        {
            cv.check(
                123,
                {
                    'number',
                    transform = function(_value)
                    end
                }
            )
        },
        { nil, {} }
    )

    -- transform error
    local r, e = cv.check(
        {a = 'asd'},
        {
            'map',
            properties = { a = 'string' },
            transform = function(value)
                value.b = 234
                error(false, 0)
            end
        }
    )
    t.assert_equals(r, nil)
    t.assert_equals(e[1].type, 'TRANSFORM_ERROR')
    t.assert_equals(
        e[1].details.transform_error, false)
end

function g.test_rename()
    t.assert_equals(
        {
            cv.check(
                {3, 2, 1, one = 4, four = '5'},
                {
                    type = 'map',
                    properties = {
                        one   = 'number',
                        two   = 'number',
                        three = 'number',
                        four  = 'string',
                    },
                    rename = {
                        [1] = 'one',
                        [2] = 'two',
                        [3] = 'three',
                    },
                }
            )
        },
        {
            {one=3, two=2, three=1, four='5'}, {}
        }
    )
end

function g.test_map_items()
    t.assert_equals(
        {
            cv.check(
                {a = 1, b = 2, c = 3},
                {'map', items = 'number'}
            )
        },
        { {a = 1, b = 2, c = 3}, {} }
    )
    local r, e = cv.check(
        {a = 1, b = 'foo', c = 3},
        {'map', items = 'number'}
    )
    t.assert_equals(r, nil)
    t.assert_equals(e[1].type, 'TYPE_ERROR')
    t.assert_equals(
        e[1].details.actual_type, 'string')
    t.assert_equals(
        e[1].details.expected_type, 'number')
end

-- -------------------------------------------------------
-- raise_errors option
-- -------------------------------------------------------

function g.test_raise_errors_compile()
    local ok, err = pcall(function()
        cv.compile(
            {type = 'invalid_type_xyz'},
            {raise_errors = true})
    end)
    t.assert_equals(ok, false)
    t.assert_is_not(err, nil)
end

function g.test_raise_errors_check()
    local s = cv.compile('string')
    local ok, err = pcall(function()
        s:check(42, {raise_errors = true})
    end)
    t.assert_equals(ok, false)
    t.assert_is_not(err, nil)
end

-- -------------------------------------------------------
-- is_schema
-- -------------------------------------------------------

function g.test_is_schema()
    local s = cv.compile('string')
    t.assert_equals(cv.is_schema(s), true)
    t.assert_equals(cv.is_schema('string'), false)
    t.assert_equals(cv.is_schema({type='string'}),
        false)
    t.assert_equals(cv.is_schema(nil), false)
end

-- -------------------------------------------------------
-- compile passes already-compiled schema through check
-- -------------------------------------------------------

function g.test_check_compiled_schema()
    local s = cv.compile('string')
    -- pass compiled schema to cv.check
    local r, e = cv.check('hello', s)
    t.assert_equals(e, {})
    t.assert_equals(r, 'hello')
end

-- -------------------------------------------------------
-- array: map-table must be rejected with ARRAY_EXPECTED
-- -------------------------------------------------------

function g.test_array_map_rejected()
    -- pure map (string keys) passed as array
    local r, e = cv.check(
        {a = 1, b = 2},
        {type = 'array'}
    )
    t.assert_equals(r, nil)
    t.assert_equals(#e, 1)
    t.assert_equals(e[1].type, 'ARRAY_EXPECTED')

    -- mixed table (sequential + string key)
    local r2, e2 = cv.check(
        {1, 2, extra = 'x'},
        {type = 'array'}
    )
    t.assert_equals(r2, nil)
    t.assert_equals(#e2, 1)
    t.assert_equals(e2[1].type, 'ARRAY_EXPECTED')
end

-- -------------------------------------------------------
-- array: make sure the error message is correct if a non-array
-- was provided instead of an array.
-- -------------------------------------------------------

function g.test_array_type_error_message()
    local r, e = cv.check(1, {type = 'array'})
    local exp = {
        details = {actual_type = "number", expected_type = "array", value = 1},
        message = "Wrong type, expected array, got number",
        path = "$",
        type = "TYPE_ERROR",
    }
    t.assert_equals(r, nil)
    t.assert_equals(e, {exp})

    r, e = cv.check(1, {type = 'map'})
    exp = {
        details = {actual_type = "number", expected_type = "map", value = 1},
        message = "Wrong type, expected map, got number",
        path = "$",
        type = "TYPE_ERROR",
    }
    t.assert_equals(r, nil)
    t.assert_equals(e, {exp})
end

-- vim: ts=4 sts=4 sw=4 et
