cmake_minimum_required(VERSION 3.24)
project(darktide_browser_runtime LANGUAGES CXX)

add_library(darktide-browser-runtime SHARED
    browser_runtime.cpp
    direct_backbuffer.inl
    steam_html.inl
)

target_compile_features(darktide-browser-runtime PRIVATE cxx_std_17)

if(MSVC)
    target_compile_options(darktide-browser-runtime PRIVATE
        /O1
        /GS-
        /GR-
        /EHs-c-
        /Zl
    )
    target_link_options(darktide-browser-runtime PRIVATE
        /NOENTRY
        /NODEFAULTLIB
        /MANIFEST:NO
        /Brepro
    )
endif()

set_target_properties(darktide-browser-runtime PROPERTIES
    PREFIX ""
    OUTPUT_NAME "darktide-browser-runtime"
)
