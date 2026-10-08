# STM32 可移植构建与调试工具

`stm32-keil-cmake-vscode-toolkit`

Keil ↔ CMake 双向转换、VS Code 一键编译调试、J-Link/ST-Link 配置与 LLVM/clangd 代码检索。

一个可复制到任意 STM32 工作区的 PowerShell 工具集，用于：

- Keil `.uvprojx` 与 GCC/CMake 工程双向转换；
- 使用 CMake、Ninja、`arm-none-eabi-gcc` 构建 Debug/Release 固件；
- 生成 VS Code 构建、下载、调试和 clangd/LLVM 代码检索配置；
- 通过芯片 JSON 选择 ST-Link、J-Link、接口频率、内存和下载/调试地址；
- 非默认 FLASH 地址会生成独立 linker script，并同步链接、下载和调试地址；
- 在存在多个工程时按序号选择，或使用 `a` 批量处理。

仓库不包含任何本机工具路径、业务工程、探针序列号或生成固件。克隆后把
[`stm32.config.json`](stm32.config.json) 复制为被 Git 忽略的 `stm32.local.json`，
再把示例工程路径替换成自己的相对路径。启动脚本会优先读取本地配置。

## 快速开始

1. 安装 PowerShell 7、CMake、Ninja 和 GNU Arm Embedded Toolchain。
2. 将相应可执行文件加入 PATH；也可以使用文档列出的环境变量。
3. 创建本地配置并按需创建本地芯片配置：

```powershell
Copy-Item ./stm32.config.json ./stm32.local.json
Copy-Item ./chips/stm32f411cc.json ./chips/my-board.local.json
```

4. 编辑 `stm32.local.json`；`tools` 可填写本机工具根目录，如需私有探针序列号则编辑 `chips/my-board.local.json`。
5. 双击 `build.bat` 构建，或双击 `convert.bat` 选择转换方向。

```powershell
pwsh ./stm32.ps1 doctor
pwsh ./stm32.ps1 build
pwsh ./stm32.ps1 convert
```

发布或提交前运行：

```powershell
pwsh ./scripts/check-release.ps1
```

还可以把公司名、用户名或内部项目代号作为额外禁止词检查：

```powershell
pwsh ./scripts/check-release.ps1 -ForbiddenText MyCompany,InternalProject
```

完整配置、目录约定、转换规则和调试说明见
[`docs/README.md`](docs/README.md)，Keil 选项映射见
[`docs/KEIL-OPTIONS.md`](docs/KEIL-OPTIONS.md)。

## 许可证与第三方文件

当前尚未为原创工具代码选择开源许可证；公开仓库前请由仓库所有者决定是否添加许可证。
`templates/` 中保留了各原始文件的许可声明，详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
