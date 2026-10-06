cmake_minimum_required(VERSION 3.24)
project(custom_assets_patcher LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "requires windows x64 and msvc")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(custom-assets-patcher
    main.cpp
    install.cpp
    assets.cpp
    manifest.cpp
    bundle.cpp
    database.cpp
    cooked.cpp
    oodle.cpp
    json.cpp
    common.cpp)
target_compile_features(custom-assets-patcher PRIVATE cxx_std_17)
target_compile_options(custom-assets-patcher PRIVATE /W4 /utf-8)
