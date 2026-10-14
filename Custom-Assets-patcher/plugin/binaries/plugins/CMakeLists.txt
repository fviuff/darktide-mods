cmake_minimum_required(VERSION 3.24)
project(custom_assets_plugin LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "requires windows x64 and msvc")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_library(custom-assets-plugin SHARED plugin.cpp)
target_compile_features(custom-assets-plugin PRIVATE cxx_std_17)
target_compile_options(custom-assets-plugin PRIVATE /W4)
set_target_properties(custom-assets-plugin PROPERTIES PREFIX "" OUTPUT_NAME "custom_assets_pluginw64_release")
