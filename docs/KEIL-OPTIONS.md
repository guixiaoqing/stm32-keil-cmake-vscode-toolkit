# Keil 与 GCC/CMake 选项映射

转换器读取 `.uvprojx` 的 Target、Output、C/C++、Assembler、Linker、User、源文件及内存配置。工程级可移植配置保存在 `<工程>/CMake-GCC/stm32-project.json`。

## 当前两个原工程

| 工程 | Keil AC5 配置 | GCC/CMake 配置 |
|---|---|---|
| COMM | Optimization Level 0，Optimize for Space | `-O0` |
| MEASURE | Optimization Level 3，Optimize for Time | `-O3` |
| 两者 | C99、All Warnings、One ELF Section per Function、短枚举 | `C_STANDARD 99`、`-Wall`、`-ffunction-sections`、`-fshort-enums` |

主配置 `stm32.config.json` 中的 `debugOptimization` 和 `releaseOptimization` 可以覆盖从 Keil 导入的优化级别。

## 可直接映射并参与 GCC 构建的选项

| Keil 配置 | `stm32-project.json` | GCC/CMake |
|---|---|---|
| Device、CPU、FPU、ABI | `device`、`arch` | `-mcpu`、`-mfpu`、`-mfloat-abi` |
| IROM/IRAM | `memory` | 链接脚本 MEMORY |
| Define/Undefine/Include Path | `defines`、`compiler.undefines`、`includeDirectories` | `-D`、`-U`、`-I` |
| Optimization | `optimization.debug/release` | `-O0/-O1/-O2/-O3/-Og/-Os/-Ofast` |
| Debug Information | `optimization.*DebugInfo` | `-g0/-g1/-g2/-g3` |
| C99 / GNU extensions | `compiler.cStandard/cExtensions` | `C_STANDARD`、`C_EXTENSIONS` |
| Warnings / Warnings as Errors | `compiler.warnings/warningsAsErrors` | `-w/-Wall/-Wextra`、`-Werror` |
| Plain Char is Signed | `compiler.signedChar` | `-fsigned-char` |
| Enum Container | `compiler.shortEnums` | `-fshort-enums` |
| Short wchar（仅 AC6） | `compiler.shortWchar` | `-fshort-wchar` |
| One ELF Section per Function | `compiler.functionSections` | `-ffunction-sections` |
| Strict ANSI | `compiler.strictAnsi` | `-pedantic` |
| Link-Time Optimization | `compiler.lto/linker.lto` | `-flto` |
| Assembler Define/Include/Misc | `assembler.*` | ASM 的 `-D/-I` 和选项 |
| Link libraries/search path/misc | `linker.libraries/libraryDirectories/options` | `target_link_libraries/directories/options` |
| No Standard Libraries | `linker.noStandardLibraries` | `-nostdlib` |
| Remove Unused Sections / Map | `linker.gcSections/mapFile` | `--gc-sections`、Map 文件 |
| Executable/Library | `output.artifactType` | `add_executable/add_library` |
| HEX/BIN | `output.hex/bin` | `objcopy -O ihex/-O binary` |
| Include in Build | 导入时过滤 `sources` | 未选中的文件不进入目标 |
| 文件级选项 | `sourceOptions[]` | CMake source properties |

可以直接在清单中添加 GCC 专用参数：

```json
{
  "compiler": {
    "commonOptions": ["-fno-strict-aliasing"],
    "debugOptions": ["-fstack-usage"],
    "releaseOptions": ["-funroll-loops"]
  },
  "assembler": {
    "options": ["-x", "assembler-with-cpp"]
  },
  "linker": {
    "libraries": ["m"],
    "libraryDirectories": [],
    "options": ["-Wl,--cref"]
  },
  "sourceOptions": [
    {
      "path": "Core/Src/main.c",
      "compileOptions": ["-O0"],
      "defines": ["MAIN_TRACE=1"],
      "includeDirectories": []
    }
  ]
}
```

## 保留但不自动错误映射的选项

ARMCC 的 ROPI、RWPI、Execute-only、Split LDM/STM、MicroLIB、Scatter 文件语义和 GCC/ld 不完全等价。这些值保存在 `compiler`、`linker` 和 `keilCompatibility` 中，但不会擅自翻译成可能改变固件 ABI 或内存布局的 GCC 参数。需要时可通过 `compiler.commonOptions`、`linker.options` 或自定义链接脚本明确配置。

Keil 的 Before Compile、Before Build、After Build 命令保存在 `buildSteps` 中，导入后默认不自动执行。原工程的 `fromelf --bin` 已由安全、等价的 `objcopy -O binary` 实现。

官方选项说明：[µVision Arm C/C++ Compiler](https://www.keil.com/support/man/docs/uv4/uv4_dg_adscc.asp)。

## 回写 `.uvprojx`

`cmake2uv` 会备份原文件为 `.uvprojx.bak`，并回写源文件、宏、头文件路径、Flash/RAM、优化、语言、告警、主要编译器选项、汇编器选项、链接库和输出类型。`Og/Os/Ofast` 回写到 ARMCC5 时使用最接近的 AC5 优化级别，并通过空间/速度倾向补充。
