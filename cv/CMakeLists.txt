if(APPLE)
    set(CMAKE_SHARED_LINKER_FLAGS
        "${CMAKE_SHARED_LINKER_FLAGS} -undefined suppress -flat_namespace")
endif()

# Add C library
add_library(cvalidator SHARED cv.c)
set_target_properties(cvalidator PROPERTIES
    PREFIX "" OUTPUT_NAME "cvalidator")

# Install module
install(FILES init.lua
    DESTINATION ${TARANTOOL_INSTALL_LUADIR}/${PROJECT_NAME}/)
install(TARGETS cvalidator LIBRARY
    DESTINATION ${TARANTOOL_INSTALL_LIBDIR}/${PROJECT_NAME}/)
