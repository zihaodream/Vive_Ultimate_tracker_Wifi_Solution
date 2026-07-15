cmake_minimum_required(VERSION 3.20)
project(utk_wifi_tracker LANGUAGES CXX)

set(OPENVR_ROOT "${CMAKE_CURRENT_LIST_DIR}/../external/openvr" CACHE PATH "Valve OpenVR SDK root")
set(DRIVER_PACKAGE_NAME "utk_wifi_tracker")
set(DRIVER_BINARY_NAME "driver_${DRIVER_PACKAGE_NAME}")

add_library(${DRIVER_BINARY_NAME} SHARED
    src/hmd_driver_factory.cpp
    src/device_provider.cpp
    src/device_provider.h
    src/tracker_device_driver.cpp
    src/tracker_device_driver.h
    src/udp_pose_receiver.cpp
    src/udp_pose_receiver.h
    src/driverlog.cpp
    src/driverlog.h
)

target_compile_features(${DRIVER_BINARY_NAME} PRIVATE cxx_std_17)
target_include_directories(${DRIVER_BINARY_NAME} PRIVATE
    "${OPENVR_ROOT}/headers"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

if(WIN32)
    target_link_libraries(${DRIVER_BINARY_NAME} PRIVATE
        "${OPENVR_ROOT}/lib/win64/openvr_api.lib"
        ws2_32
    )
    set_target_properties(${DRIVER_BINARY_NAME} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/bin/win64"
        ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/lib"
    )
endif()

add_custom_command(TARGET ${DRIVER_BINARY_NAME} PRE_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/resources"
        "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/driver.vrdrivermanifest"
        "${CMAKE_BINARY_DIR}/${DRIVER_PACKAGE_NAME}/driver.vrdrivermanifest"
)
