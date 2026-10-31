set_xmakever("3.0.0")
set_project("otto-native")
set_version("1.0.0")
set_languages("c++20")
add_rules("mode.debug", "mode.release")
set_policy("build.warning", true)

-- Use the release archive's matching AsmJit, rather than a floating Git version.
package("otto-blend2d")
    set_homepage("https://blend2d.com")
    set_description("Blend2D with the matching bundled AsmJit")
    set_license("Zlib")
    set_urls("https://blend2d.com/download/blend2d-$(version).tar.gz")
    add_versions("0.11.1", "f46d61b6aa477fea1a353a41f5906d4e861817ae059ed22fc6ecdd50ff859dd2")
    on_load(function (package)
        package:add("defines", "BL_STATIC")
        package:add("links", "blend2d")
        if package:is_plat("linux", "bsd") then
            package:add("syslinks", "pthread", "rt", "m")
        end
    end)
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=Release", "-DBLEND2D_STATIC=ON",
            "-DBLEND2D_TEST=OFF", "-DBLEND2D_NO_JIT=OFF"
        })
    end)
package_end()

-- SDL discovers the host's window-system backends. Its source version and hash
-- are fixed here; only the final framebuffer is uploaded to its renderer.
package("otto-sdl3")
    set_homepage("https://libsdl.org")
    set_description("SDL3 window and input backend")
    set_license("Zlib")
    set_urls("https://www.libsdl.org/release/SDL3-$(version).zip")
    add_versions("3.4.16", "5f399fdfbc040169ef4418a3cb99ccc5a0641681f7ccc1da66eeec3c97fa4076")
    on_load(function (package)
        package:add("links", "SDL3")
    end)
    on_install(function (package)
        import("package.tools.cmake").install(package, {
            "-DCMAKE_BUILD_TYPE=Release", "-DSDL_SHARED=ON", "-DSDL_STATIC=OFF",
            "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF", "-DSDL_TEST_LIBRARY=OFF"
        })
    end)
package_end()

add_requires("otto-blend2d 0.11.1", "otto-sdl3 3.4.16", {system = false})

target("otto")
    set_kind("binary")
    add_files("src/*.cpp")
    add_includedirs("src")
    add_packages("otto-blend2d", "otto-sdl3")
    set_warnings("all", "extra")
    if is_mode("release") then
        set_optimize("fastest")
    end
    if is_plat("linux") then
        add_rpathdirs("$ORIGIN")
    elseif is_plat("macosx") then
        add_rpathdirs("@loader_path")
    end
    after_build(function (target)
        os.cp("assets", target:targetdir())
        local sdl = target:pkg("otto-sdl3")
        for _, pattern in ipairs({"lib/libSDL3.so*", "lib/libSDL3*.dylib", "bin/SDL3.dll"}) do
            for _, file in ipairs(os.files(path.join(sdl:installdir(), pattern))) do
                os.cp(file, target:targetdir())
            end
        end
    end)

target("otto-tests")
    set_kind("binary")
    set_default(false)
    add_files("tests/timeline_test.cpp")
    add_includedirs("src")
    set_warnings("all", "extra")
    add_tests("timeline")

target("otto-relief-tests")
    set_kind("binary")
    set_default(false)
    add_files("tests/relief_test.cpp", "src/relief.cpp")
    add_includedirs("src")
    set_warnings("all", "extra")
    add_tests("relief")
