# Include after the hosting driver adds exact Core7b11 as target LatticeCore.
add_executable(RetentionFloorRaceProbe "${CMAKE_CURRENT_LIST_DIR}/probe.cpp")
target_link_libraries(RetentionFloorRaceProbe PRIVATE LatticeCore Threads::Threads ${CMAKE_DL_LIBS})
if(APPLE)
  target_link_options(RetentionFloorRaceProbe PRIVATE "-Wl,-map,${CMAKE_BINARY_DIR}/floor-race.map")
else()
  target_link_options(RetentionFloorRaceProbe PRIVATE "-Wl,-Map,${CMAKE_BINARY_DIR}/floor-race.map")
endif()
