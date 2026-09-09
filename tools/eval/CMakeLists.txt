# mixime-eval: headless eval CLI for the engine (see mixime_eval.cpp).
#
# This directory is added via add_subdirectory() from Source/Engine/CMakeLists.txt
# so the eval CLI builds alongside the engine's own tests, using the same
# McBopomofoLMLib / MandarinLib / gramambular2_lib targets.

set(MIXIME_ENGINE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../Source/Engine")

add_executable(mixime-eval mixime_eval.cpp)
target_include_directories(mixime-eval PRIVATE "${MIXIME_ENGINE_SOURCE_DIR}")
target_link_libraries(mixime-eval PRIVATE
        McBopomofoLMLib
        MandarinLib
        gramambular2_lib
        MixedScriptLib)
