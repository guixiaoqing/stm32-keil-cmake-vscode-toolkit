# STM32 可移植构建与调试工具

`stm32-keil-cmake-vscode-toolkit`

Keil ↔ CMake 双向转换、VS Code 一键编译调试、J-Link/ST-Link 配置与 LLVM/clangd 代码检索。

这是一个可独立复制的 STM32 工程配置工具。它把 Keil MDK 的 `.uvprojx` 转换为 GCC CMake 工程，并生成 VS Code 编译、下载、调试及本机 LLVM/clangd 索引配置。转换后的 `stm32-project.json` 是可编辑的中间清单，也可将清单中的源文件、宏、头文件目录和内存布局同步回原 `.uvprojx`。

该目录不包含任何产品业务源码，可以整体复制到其他仓库。每个目标工程的 CMake 工程统一生成在源码根目录的 `CMake-GCC/`，与 `MDK-ARM/` 平级。

## 目录结构

```text
stm32-keil-cmake-vscode-toolkit/
├─ stm32.ps1               # 独立目录快捷入口，可自动发现同级 STM32 工程
├─ build.bat               # Windows 无参数入口，双击或终端直接运行
├─ convert.bat             # Keil/CMake 双向转换交互入口
├─ stm32.config.json       # 默认总配置；可零参数运行
├─ stm32.local.json        # 可选本机配置，优先读取且被 Git 忽略
├─ chips/                  # 可复用芯片/调试器配置
│  ├─ stm32f411cc.json     # STM32F411CC 配置示例
│  ├─ stm32f411cc-jlink.json # STM32F411CC + J-Link 配置
│  └─ stm32h743zi.json     # STM32H743ZI 配置示例
├─ configs/                # 一个工程对应一个入口配置文件
│  └─ project.example.json
├─ scripts/
│  ├─ stm32-project.ps1    # 转换、生成、编译、下载和环境检查核心实现
│  └─ check-release.ps1    # 提交前扫描本机路径、序列号和构建产物
├─ templates/              # CMake -> Keil 所需的编译器/芯片模板
│  └─ stm32f411xe/
│     ├─ startup_stm32f411xe.s # ARMCC5 启动文件
│     └─ gcc/startup_stm32f411xe.s # GNU Arm 启动文件
└─ docs/
   ├─ README.md            # 使用说明
   └─ KEIL-OPTIONS.md      # Keil 与 GCC/CMake 选项映射
```

`.github/workflows/validate.yml` 会在 GitHub push 和 pull request 时重复执行发布检查、JSON 解析和 PowerShell 语法检查。

目标工程结构：

```text
MySTM32Project/
├─ Core/
├─ Drivers/
├─ MDK-ARM/
├─ CMake-GCC/
│  ├─ stm32-project.json
│  ├─ CMakeLists.txt
│  ├─ CMakePresets.json
│  ├─ cmake/
│  └─ build/{debug,release}/
└─ .vscode/
```

## 环境

- PowerShell 7（Windows PowerShell 5.1 也可运行）
- CMake 3.20+、Ninja
- GNU Arm Embedded Toolchain (`arm-none-eabi-gcc`)
- LLVM `clangd`
- 下载使用 STM32CubeProgrammer CLI
- 调试使用 VS Code 扩展 Cortex-Debug；默认后端为 OpenOCD
- 使用 J-Link 调试时必须另外安装 SEGGER J-Link Software and Documentation Pack；STM32CubeProgrammer 自带的 `JLink_x64.dll` 只能供下载器调用，不能代替 `JLinkGDBServerCL.exe`

工具优先检查 PATH，也支持用环境变量指定安装目录。本机路径不要写入准备提交的配置文件；可在 PowerShell 配置中设置：

```powershell
$env:STM32_GCC_ROOT = '<path-to-arm-gnu-toolchain>'
$env:ARM_GNU_TOOLCHAIN_ROOT = '<path-to-arm-gnu-toolchain>'
$env:STM32_CUBE_CLT_ROOT = '<path-to-STM32CubeCLT>'
$env:STM32_CUBEMX_ROOT = '<path-to-STM32CubeMX>'
$env:LLVM_ROOT = '<path-to-LLVM>'
$env:KEIL_ROOT = '<path-to-Keil>'
$env:JLINK_ROOT = '<path-to-J-Link>'
```

通常只需要设置 PATH 或其中一个对应变量。

J-Link 安装后，工具会从 PATH、`JLINK_ROOT` 以及 Windows 的 `Program Files/SEGGER/JLink*` 目录自动查找 `JLinkGDBServerCL.exe`。如果安装在自定义位置，在 `stm32.local.json` 中填写：

```json
{
  "tools": {
    "jlinkRoot": "<path-to-SEGGER-JLink>"
  }
}
```

## 使用

推荐先运行 `Copy-Item ./stm32.config.json ./stm32.local.json`，之后只编辑根目录的 `stm32.local.json`。该文件被 Git 忽略并且优先于公共示例配置读取，可避免误提交工程路径和探针序列号。`projects` 保存工程列表，`action` 选择默认动作；`activeProject` 保留为单工程及非交互兼容默认值：

```json
{
  "action": "build",
  "activeProject": "example",
  "tools": {
    "gccRoot": "",
    "llvmRoot": "",
    "cubeCltRoot": "",
    "cubeMxRoot": "",
    "keilRoot": "",
    "jlinkRoot": ""
  },
  "projects": {
    "example": {
      "projectRoot": "../MySTM32Project",
      "cmakeProjectDir": "CMake-GCC",
      "uvprojx": "../MySTM32Project/MDK-ARM/MySTM32Project.uvprojx",
      "chipConfig": "chips/stm32f411cc.json",
      "targetName": "MySTM32Project",
      "keilCompiler": "armcc5",
      "conversionBackend": "auto",
      "buildType": "Debug",
      "debugOptimization": "Og",
      "releaseOptimization": "Os",
      "defines": ["USE_HAL_DRIVER", "STM32F411xE", "APP_FEATURE=1"]
    }
  }
}
```

`tools` 中的路径只应填写在 `stm32.local.json`。所有值都是可选的；空值表示从 PATH 查找。它们分别对应 GNU Arm、LLVM、STM32CubeCLT、STM32CubeMX、Keil 和 J-Link 的安装根目录。相对路径以配置文件所在目录为基准。

零参数执行会读取上述配置。存在多个工程时按 JSON 中的顺序显示选择菜单：

```powershell
build.bat
```

菜单支持输入 `1`、`2`、`3` 等序号构建一个工程，输入 `a` 构建全部工程。只有一个工程时会直接构建；不需要修改 BAT。

```text
可用的 STM32 工程：
  [1] app      (Application)
  [2] boot     (Bootloader)
  [a] 全部工程
请选择要构建的工程:
```

PowerShell 中也可以直接运行：

```powershell
.\build.bat
```

BAT 同时透传可选参数，因此高级用法仍可写成 `build.bat generate` 或 `build.bat build -Config Release`。

`build.bat` 和 `convert.bat` 完成后都会显示 `SUCCESS` 或 `FAILED`、退出码，并停留在 `Press any key to close this window...`，按任意键后才关闭窗口。VS Code 的构建任务直接调用 `stm32.ps1`，不会被 BAT 的等待影响。

自动化或 CI 中不希望出现菜单时，可以用名称或序号直接选择：

```powershell
.\build.bat build -Project app
.\build.bat build -Project 2
.\build.bat build -Project a
```

## Keil/CMake 双向转换菜单

运行：

```powershell
.\convert.bat
```

先选择转换方向：

```text
[1] Keil (.uvprojx) -> CMake-GCC
[2] CMake-GCC -> Keil (.uvprojx)
```

随后会显示与构建相同的工程列表，可输入工程序号或输入 `a` 转换全部工程。CMake 回写 Keil 前会将原文件备份为 `.uvprojx.bak`。

方向 2 支持两类输入：

- 工具生成的 CMake：读取 `<projectRoot>/<cmakeProjectDir>/stm32-project.json`。
- 只有原生 CMake 的工程：读取 `<projectRoot>/CMakeLists.txt` 和 `CMakePresets.json`，调用 CMake 生成 `compile_commands.json` 后提取源文件、包含目录、宏和 CPU 参数，再在配置项 `uvprojx` 指定的位置新建 Keil 工程。

使用 Arm Compiler 5 时设置 `"keilCompiler": "armcc5"`。转换器会排除 GCC 专用的 `syscalls.c`、`sysmem.c` 与 GNU 启动文件，并从芯片配置的 `keilStartupTemplate` 复制 MDK 启动文件。若使用 Arm Compiler 6，可设置为 `armclang6`。

Keil → CMake 的 `conversionBackend` 有三个选项：

- `auto`（推荐）：工程有 `.ioc` 且检测到 STM32CubeMX 时，在系统临时目录调用 CubeMX 生成官方 CMake/GCC 基础文件；转换器只导入 GNU 启动文件、链接脚本、`syscalls.c` 和 `sysmem.c`，再与 Keil 的业务源码、宏和头文件配置合并。临时目录随后自动删除，原工程源码不会被 CubeMX 覆盖。
- `cubemx`：强制使用上述 CubeMX 混合后端；缺少 `.ioc`、CubeMX、固件包或生成失败时直接报错。
- `parser`：完全使用 `.uvprojx` 解析和 `chips/`、`templates/` 中的配置，不调用 CubeMX。

CubeMX 只在执行转换时运行；普通 `build/configure` 不会再次启动 CubeMX。

新增其他芯片时，在对应 `chips/*.json` 中填写 Keil Pack 的精确 `keilDevice`，并分别提供 `keilStartupTemplate`（ARMCC/ARMASM 语法）与 `gccStartupTemplate`（GNU assembler 语法）。转换器会按目标工具链自动选择启动文件；芯片差异留在配置和模板中，而不是写死在转换脚本里。

非交互调用：

```powershell
.\convert.bat -Direction keil2cmake -Project 1
.\convert.bat -Direction cmake2keil -Project boot
.\convert.bat -Direction keil2cmake -Project a
```

对于新工程，如果 `<工程根目录>/CMake-GCC/stm32-project.json` 尚不存在，`build` 会先自动读取配置中的 `.uvprojx` 和芯片配置完成导入，然后继续编译，无需手工切换 `action`。

命令行参数仍然支持，并且优先于配置文件，适合临时覆盖：

```powershell
pwsh ./stm32.ps1 build -Config Release
```

如果希望每个工程使用独立文件，也可使用 `configs/*.json` 并通过 `-ConfigFile` 指定；其中路径相对于该 JSON 文件：

```json
{
  "projectRoot": "../../MySTM32Project",
  "cmakeProjectDir": "CMake-GCC",
  "uvprojx": "../../MySTM32Project/MDK-ARM/MySTM32Project.uvprojx",
  "chipConfig": "../chips/stm32f411cc-jlink.json",
  "targetName": "MySTM32Project",
  "buildType": "Debug",
  "debugOptimization": "Og",
  "releaseOptimization": "Os"
}
```

首次导入及生成：

```powershell
pwsh ./stm32.ps1 uv2cmake -ConfigFile ./configs/project.example.json
```

以后编译只需要配置文件：

```powershell
pwsh ./stm32.ps1 build -ConfigFile ./configs/project.example.json
```

在本工具目录运行以下命令会显示工程选择菜单：

```powershell
cd <path-to-tool>\stm32-keil-cmake-vscode-toolkit
pwsh ./stm32.ps1 build -Config Debug
```

也可以用独立配置文件构建指定工程：

```powershell
pwsh ./stm32.ps1 build -ConfigFile ./configs/project.example.json
```

## 编译优化等级

优化等级由配置文件控制，不需要写进命令行：

```json
{
  "buildType": "Debug",
  "debugOptimization": "Og",
  "releaseOptimization": "Os"
}
```

- `buildType` 决定无参数构建使用 Debug 还是 Release。
- `debugOptimization` 决定 Debug 优化等级，默认 `Og`，并生成 `-g3` 调试信息。
- `releaseOptimization` 决定 Release 优化等级，默认 `Os`，并生成 `-g1` 调试信息。
- 可选值：`O0`、`O1`、`O2`、`O3`、`Og`、`Os`、`Ofast`。

最终选择也会写入工程的 `CMake-GCC/stm32-project.json`。生成后的真实 GCC 命令可在 `CMake-GCC/build/<配置>/compile_commands.json` 中检查。

## 工程宏定义

每个工程的全部有效宏都显示在总配置的 `defines` 中。Keil → CMake 转换会自动读取 `.uvprojx` 的 Define 项，合并芯片宏并写回当前工程配置；同事可以直接在同一数组中添加或删除自定义宏：

```json
{
  "defines": [
    "USE_HAL_DRIVER",
    "STM32F411xE",
    "fflush=stm32_fflush",
    "APP_FEATURE=1",
    "BOARD_REV=2"
  ]
}
```

宏使用 `NAME` 或 `NAME=value` 格式。`build` 以该列表为工程宏来源，并把芯片配置补充的最终有效宏同步回这里；不会删除同事手工添加的条目。兼容旧配置的 `extraDefines` 仍可读取，但新配置统一使用 `defines`。所有宏同时参与以下输出：

- GCC/CMake 的 `target_compile_definitions`；
- `compile_commands.json` 与 clangd/LLVM 索引；
- CMake → Keil 时 `.uvprojx` 的 C/C++ Define 项。

Keil 的 C/C++、汇编、链接、输出、内存、逐文件和构建步骤选项的详细映射见 [KEIL-OPTIONS.md](KEIL-OPTIONS.md)。可等价的选项会参与 GCC/CMake 构建；ARMCC 专属且没有可靠 GCC 等价项的配置会保留在 `keilCompatibility` 中，不会被静默丢弃或错误转换。

`flash` 不会自动操作多个工程，必须提供 `-ProjectRoot`。

复制整个工具目录和源码工程到另一台电脑后，只需安装 CMake/Ninja/GNU Arm/LLVM，并运行一次 `generate`。工具会重新探测新电脑的工具路径。

先检查本机工具：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 doctor
```

Keil 转 CMake（`ProjectRoot` 是源码工程根目录；CMake 文件生成在同级的 `CMake-GCC/`）：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 uv2cmake `
  -Uvprojx ./MyProject/MDK-ARM/MyProject.uvprojx `
  -ProjectRoot ./MyProject `
  -ChipConfig ./stm32-keil-cmake-vscode-toolkit/chips/stm32f411cc.json
```

编译：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 build -ProjectRoot ./MyProject -Config Debug
```

CMake 清单同步回 Keil（原文件会先备份为 `.uvprojx.bak`）：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 cmake2uv -ProjectRoot ./MyProject
```

下载：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 flash -ProjectRoot ./MyProject -Config Debug
```

## 指定下载和调试位置

芯片可变项放在独立配置文件中。仓库自带 `chips/stm32f411cc.json` 与 `chips/stm32h743zi.json` 两个范例；复制其中之一即可添加新型号。配置会覆盖从 Keil 工程读取到的芯片、架构、内存和调试参数：

```powershell
pwsh ./stm32-keil-cmake-vscode-toolkit/stm32.ps1 generate `
  -ProjectRoot ./MyProject `
  -ChipConfig ./my-chips/stm32g474re.json
```

选择过的配置路径会记录到 `<工程根目录>/CMake-GCC/stm32-project.json` 的 `chipConfig` 字段。`generate` 适合切换芯片；`configure` 和 `build` 会在运行前根据当前工程清单自动重建链接脚本与 VS Code 配置。

推荐复制一个芯片配置为 `*.local.json`，保留芯片物理 FLASH 范围，只修改应用下载地址。例如 STM32F411CC 从 `0x08010000` 开始运行：

```json
{
  "memory": {
    "flash": { "origin": "0x08000000", "length": "0x00040000" },
    "ram": { "origin": "0x20000000", "length": "0x00020000" }
  },
  "defaultLinkAddress": "0x08000000",
  "loadAddress": "0x08010000",
  "debugAddress": "0x08010000",
  "addressPolicy": "unified"
}
```

`unified` 是默认策略。工具会自动得到：

- 链接起始地址：`0x08010000`；
- 下载地址和调试地址：`0x08010000`；
- 可用 FLASH 长度：`0x00030000`，即从物理 FLASH 总长度中扣除 `0x10000`；
- 独立链接文件：`CMake-GCC/cmake/stm32-linker-08010000.ld`。

默认的 `cmake/stm32-linker.ld` 不会被偏移配置覆盖。CMake 会从 `stm32-project.json` 的 `linkerScript` 字段选择当前地址对应的文件。CubeMX 混合模式也会复制原始 `.ld` 后只修改副本的 MEMORY 区域，原始 CubeMX 模板保持不变。

重新执行 `uv2cmake` 会从 Keil 读取工程配置，因此若 Keil 是主工程，也应把 IROM1 起始地址设置为相同值。应用位于偏移地址时，还必须由 bootloader 或应用初始化代码正确设置 `SCB->VTOR`，否则中断向量仍可能指向默认地址。

- `memory.flash.origin`：生成后的实际链接地址。在 `unified` 策略下会自动对齐到 `loadAddress`。
- `loadAddress`：`.bin` 下载地址。
- `debugAddress`：应用向量表基地址。VS Code 调试会先把 VTOR 指向这里，再从该地址读取 MSP、从 `debugAddress + 4` 读取 Reset_Handler，最后运行到 `main`；不要把它理解为普通指令地址。
- `defaultLinkAddress`：芯片/工程默认链接地址，用于判断是否生成带地址后缀的独立链接文件。
- `addressPolicy`：默认 `unified`，统一链接、下载和调试地址；高级场景可设为 `independent`，此时三者互不改写，并由使用者自行保证链接脚本和加载方式正确。
- `debug.openocdConfigFiles`：OpenOCD probe/target 配置。
- `debug.svdFile`：可选 SVD 文件，相对于工程根目录。

## VS Code

打开源码工程根目录。源码工程内只生成 `.vscode`；其他文件集中在工具目录：

- `.vscode/tasks.json`：配置、编译、下载。
- `.vscode/launch.json`：下载调试、附加到配置的向量表，并运行到 `main`。
- `.vscode/settings.json`：本机 GCC、Programmer、OpenOCD、clangd 路径。
- `CMake-GCC/CMakePresets.json`：Debug / Release。
- `CMake-GCC/cmake/`：工具链、链接脚本、源文件清单。
- `CMake-GCC/build/debug/compile_commands.json`：LLVM 语义检索数据库。

工具会根据芯片配置的 `debug.probe` 生成调试后端。本机路径会写入工作区设置 `stm32.debugServerPath`；换电脑后运行一次 `generate` 即可重新探测。使用 J-Link 时，将芯片配置的 `debug.probe` 改为 `jlink`。

每次执行 `build` 都会重新生成 CMake、链接脚本、clangd、`.vscode/tasks.json` 和 `.vscode/launch.json`，并在编译后自动检查 ELF 的向量表、初始 MSP、Reset_Handler、入口符号和调试配置。只有这些内容与芯片 JSON 一致时才会显示 `STM32 build verification PASSED`。工程内生成的 `.vscode` 文件不需要手工维护。

对于从 `0x08010000` 等偏移地址运行的应用，生成的调试配置会执行等价于以下操作的 GDB 命令：

```text
VTOR = 0x08010000
MSP  = *(uint32_t *)0x08010000
PC   = *(uint32_t *)0x08010004
continue to main
```

这样下载调试不依赖默认 Flash 地址处已经存在 bootloader。实际脱离调试器上电运行时仍需要 bootloader 跳转到应用，或由启动流程正确设置 VTOR、MSP 和 PC。

## 配置多个工程

在 `stm32.local.json` 的 `projects` 中按希望显示的顺序加入多个工程。例如：

```json
{
  "projects": {
    "app": {
      "projectRoot": "../Application",
      "cmakeProjectDir": "CMake-GCC",
      "uvprojx": "../Application/MDK-ARM/Application.uvprojx",
      "chipConfig": "chips/stm32f411cc.json",
      "targetName": "Application"
    },
    "boot": {
      "projectRoot": "../Bootloader",
      "cmakeProjectDir": "CMake-GCC",
      "uvprojx": "../Bootloader/MDK-ARM/Bootloader.uvprojx",
      "chipConfig": "chips/stm32f411cc-jlink.json",
      "targetName": "Bootloader"
    }
  }
}
```

生成物位于各工程的 `CMake-GCC/build/debug/`，包括 `.elf`、`.hex`、`.bin`、`.map` 和 `compile_commands.json`。

## 添加新芯片

复制 `chips/stm32f411cc.json`，修改以下字段：

- `device`：芯片完整型号。
- `arch.cpu`、`arch.fpu`、`arch.floatAbi`：CPU/FPU ABI。
- `memory.flash`、`memory.ram`：链接内存起始地址和长度。
- `loadAddress`：BIN 下载地址。
- `debugAddress`：应用向量表基地址；调试器从这里恢复 VTOR/MSP/Reset_Handler，并运行到 `main`。
- `defaultLinkAddress`：默认链接地址。
- `addressPolicy`：地址同步策略，通常使用 `unified`。
- `definesAppend`：芯片系列预处理宏。
- `debug.probe`：`stlink`、`openocd` 或其他 Cortex-Debug 后端。
- `debug.interface`：`swd` 或 `jtag`。
- `debug.speedKhz`：调试接口频率，单位 kHz。
- `debug.serialNumber`：可选探针序列号；多探针环境建议指定。
- `debug.runToEntryPoint`：下载后自动运行并停止的函数名，默认 `main`。
- `debug.serverArgs`：额外传给 GDB Server 的参数数组。
- `debug.openocdConfigFiles`：OpenOCD 接口及目标配置。
- `debug.svdFile`：可选的芯片 SVD 文件。

本机使用 J-Link 时，可直接切换：

```powershell
pwsh ./stm32.ps1 generate `
  -ProjectRoot ../MySTM32Project `
  -ChipConfig ./chips/stm32f411cc-jlink.json
```

## 转换规则和限制

- `.uvprojx -> CMake`：读取目标、源文件、宏、头文件目录、IROM/IRAM；MDK 汇编启动文件自动替换为同名 CMSIS GCC 启动文件。
- 启动文件识别：脚本通过汇编语法识别 `AREA/EXPORT/IMPORT/DCD` 等 ARMASM 文件，不依赖固定工程名或固定 `MDK-ARM` 目录名。优先查找工程自身的同名 GNU 启动文件，找不到时使用芯片配置的 `gccStartupTemplate`。
- `CMake -> .uvprojx`：存在 `stm32-project.json` 时以清单为准；只有原生 CMake 时通过 CMake File API 的实际产物 `compile_commands.json` 提取当前配置的源文件、宏、头文件目录和编译参数，并创建新的 `.uvprojx`。
- 任意手写 CMake 是图灵完备的，无法只靠文本做到完全静态反解析。本工具读取 CMake 实际生成的编译数据库，因此能转换当前构建配置；自定义链接命令、生成器表达式的所有分支和非编译目标仍可能需要在芯片或工程配置中补充。
- Keil scatter 文件不能直接交给 GNU ld；工具会生成 `cmake/stm32-linker.ld`。
