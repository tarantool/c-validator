package = 'cv'
version = 'scm-1'

source = {
    url = "git+https://github.com/tarantool/c-validator.git",
    branch = 'master';
}

description = {
    summary  = 'Fast schema validator for Tarantool';
    detailed = [[
cv is a schema-based validator for Tarantool,
implemented in C for maximum performance.
It is compatible with the aeon.common.validator API
and provides ~10x speedup over the pure-Lua version.

Supports: maps, arrays, oneof, rename, defaults,
transforms, constraints, uuid, tuple, int64/uint64,
box.NULL, and OpenAPI 3.1 schema serialization.
    ]];
    homepage = 'https://github.com/tarantool/c-validator';
    license  = 'BSD-2-Clause';
}

dependencies = {
    'lua == 5.1';
}

external_dependencies = {
    TARANTOOL = {
        header = 'tarantool/module.h';
    };
}

build = {
    type = 'cmake';
    variables = {
        CMAKE_BUILD_TYPE         = 'RelWithDebInfo';
        TARANTOOL_DIR            = '$(TARANTOOL_DIR)';
        TARANTOOL_INSTALL_LIBDIR = '$(LIBDIR)';
        TARANTOOL_INSTALL_LUADIR = '$(LUADIR)';
    };
}
-- vim: syntax=lua ts=4 sts=4 sw=4 et
