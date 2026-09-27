# custom-triplets/x64-linux-custom.cmake

set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)

# Cloud CPUs may not expose invariant TSC. Compile the runtime itself with
# the same timer mode as plugin_debug_profiler; consumer defines alone do
# not change Tracy's initialization or its clock source.
if (PORT STREQUAL "tracy")
    list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS -DTRACY_TIMER_FALLBACK=ON)
endif ()

# Keep CI installs release-only to avoid building both variants there.
if ((DEFINED ENV{GITHUB_ACTIONS} AND NOT "$ENV{GITHUB_ACTIONS}" STREQUAL "")
	OR (DEFINED ENV{CI} AND NOT "$ENV{CI}" STREQUAL ""))
	set(VCPKG_BUILD_TYPE release)
endif ()
