# bopomix-eval: headless eval CLI for the engine (see bopomix_eval.cpp).
#
# This directory is added via add_subdirectory() from Source/Engine/CMakeLists.txt
# so the eval CLI builds alongside the engine's own tests, using the same
# McBopomofoLMLib / MandarinLib / gramambular2_lib targets.

set(BOPOMIX_ENGINE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../Source/Engine")

add_executable(bopomix-eval bopomix_eval.cpp)
target_include_directories(bopomix-eval PRIVATE "${BOPOMIX_ENGINE_SOURCE_DIR}")
target_link_libraries(bopomix-eval PRIVATE
        McBopomofoLMLib
        MandarinLib
        gramambular2_lib
        MixedScriptLib)
