cmake_minimum_required(VERSION 3.24)
project(custom_assets_patcher LANGUAGES CXX)

add_executable(custom-assets-patcher
    custom_assets_patcher.cpp
)

target_compile_features(custom-assets-patcher PRIVATE cxx_std_17)

if(MSVC)
    target_compile_options(custom-assets-patcher PRIVATE
        /O2
    )
endif()

set_target_properties(custom-assets-patcher PROPERTIES
    PREFIX ""
    OUTPUT_NAME "custom-assets-patcher"
)
