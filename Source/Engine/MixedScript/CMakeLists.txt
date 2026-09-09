cmake_minimum_required(VERSION 3.12)
project(MixedScript)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC")

# P1 zh/en mixed-typing (see ~/.claude/plans/zhuyin-ime-personal.md). Mirrors
# the Mandarin/ and gramambular2/ subdirectory pattern: a small static lib
# plus its own gtest binary, consumed by McBopomofoLMLib (McBopomofoLM
# merges LatinPassthroughLM into its unigram dispatch) and by KeyHandler.mm
# (drives MixedScriptTracker directly) and by tools/eval/mixime_eval.cpp
# (the `--mixed` flag drives the same tracker for parity between the app
# and the eval harness).
add_library(MixedScriptLib
        bopomofo_shape_tracker.h
        bopomofo_shape_tracker.cpp
        latin_lexicon.h
        latin_lexicon.cpp
        latin_passthrough_lm.h
        latin_passthrough_lm.cpp
        mixed_script_tracker.h
        mixed_script_tracker.cpp)
target_link_libraries(MixedScriptLib PUBLIC MandarinLib gramambular2_lib)

if (ENABLE_CLANG_TIDY)
    set_target_properties(MixedScriptLib PROPERTIES CXX_CLANG_TIDY "${CLANG_TIDY_COMMAND}")
endif ()

if (ENABLE_TEST)
        enable_testing()
        if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
                cmake_policy(SET CMP0135 NEW)
        endif()

        add_executable(MixedScriptTest
                bopomofo_shape_tracker_test.cpp
                latin_lexicon_test.cpp
                mixed_script_tracker_test.cpp)
        target_link_libraries(MixedScriptTest GTest::gtest_main MixedScriptLib)
        include(GoogleTest)
        gtest_discover_tests(MixedScriptTest)

        add_custom_target(
                runMixedScriptTest
                COMMAND ${CMAKE_CURRENT_BINARY_DIR}/MixedScriptTest
        )
        add_dependencies(runMixedScriptTest MixedScriptTest)
endif ()
