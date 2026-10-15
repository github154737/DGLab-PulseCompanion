# Some restricted Windows runners expose reparse points but cannot traverse them.
# The build script supplies real cache paths; normal developer builds retain
# Flutter's generated loader when that optional file is absent.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/flutter/plugin_paths.cmake")
  include(flutter/plugin_paths.cmake)
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/flutter/generated_plugins.cmake" plugin_loader)
  string(REPLACE [=[flutter/ephemeral/.plugin_symlinks/${plugin}]=]
    [=[${AIHAPTICS_PLUGIN_${plugin}}]=] plugin_loader "${plugin_loader}")
  string(REPLACE [=[flutter/ephemeral/.plugin_symlinks/${ffi_plugin}]=]
    [=[${AIHAPTICS_PLUGIN_${ffi_plugin}}]=] plugin_loader "${plugin_loader}")
  file(WRITE "${PROJECT_BINARY_DIR}/resolved_plugins.cmake" "${plugin_loader}")
  include("${PROJECT_BINARY_DIR}/resolved_plugins.cmake")
else()
  include(flutter/generated_plugins.cmake)
endif()
