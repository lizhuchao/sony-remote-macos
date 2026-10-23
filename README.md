# Sony BRAVIA Remote

macOS 原生 Sony BRAVIA 局域网遥控器。使用 Sony IRCC-IP、REST API 和 Wake-on-LAN，不依赖 ADB；已在 KD-55X9000H 验证。

当前版本：**1.3（10）**

## 功能

- 方向键、OK、Home、Back、音量、静音和电源控制
- 断线后自动恢复连接，支持 Wake-on-LAN 唤醒
- 将 Mac 输入法、复制和粘贴的完整文本发送到电视当前输入框
- 首次启动自动扫描局域网中的 Sony BRAVIA，也支持手动输入 IP
- 保存和切换多个电视 Profile，同一时间控制一台电视
- Profile 保存名称、型号、位置、IP、MAC 和独立的 Keychain PSK
- 英文和简体中文界面，跟随 macOS 首选语言；其他语言默认英文

## 系统要求

- macOS 13 或更高版本
- Mac 与电视处于同一局域网
- 电视支持 Sony IRCC-IP、REST API 和 Pre-Shared Key 认证
- 从源码构建需要 Apple Swift 工具链

不需要 Android Platform Tools 或 ADB 调试授权。

## 电视端设置

不同 BRAVIA 固件的菜单名称可能略有差异。在电视网络或家庭网络设置中：

1. 启用 **Remote Start**。
2. 启用 **Simple IP Control**。
3. 将 IP Control 认证方式设为 **Pre-Shared Key**。
4. 设置一个 PSK，并在 Mac 应用中输入相同内容。

首次启动会显示三步指引并自动扫描。发现流程先使用 Sony ScalarWebAPI 的 SSDP/UPnP，再使用当前 `/24` 网段的 `/sony/system` 验证作为后备。访客网络、AP 隔离或电视待机可能阻止扫描，此时可手动输入 IP。

## 运行与构建

直接运行：

```zsh
./run.sh
```

重新构建：

```zsh
./build.sh
```

生成的应用位于 `build/Sony BRAVIA Remote.app`。

## 键盘操作

| 按键 | 电视操作 |
| --- | --- |
| `↑` `↓` `←` `→` | 方向键 |
| `Return` | OK |
| `Esc` | 返回 |
| `Home` 或 `H` | 主页 |
| `M` 或键盘静音媒体键 | 静音 |
| `⌘` + 音量媒体键 | 电视音量加、减、静音 |
| `⌘K` | 打开电视键盘 |
| 单独按住 `⌘` 约 0.7 秒 | 显示快捷键说明 |

`Backspace` 和 `Delete` 保留给文字编辑。发送文字前，需要先在电视应用（例如 TiviMate）中激活输入框；Sony `setTextForm` 会把完整文本写入当前输入框。

## 多电视 Profile

主界面显示“位置 · 型号”，位置可选客厅、卧室、书房或自定义。每台电视的 PSK 独立保存在 macOS Keychain；更换 Mac 后需要重新输入，不会随 Profile 自动迁移。

## 协议分工

- **IRCC-IP**：遥控按键
- **REST API**：设备信息、连接状态、文字输入和电源控制
- **Wake-on-LAN**：待机或 Suspend 后唤醒

首次验证成功后，应用通过 REST API 保存电视 MAC 地址供 Wake-on-LAN 使用。

## 隐私

PSK 仅保存在本机 macOS Keychain，不写入源码、配置文件或 Git。应用只与局域网中的电视通信，不依赖云端服务。

---

## English

Sony BRAVIA Remote is a native macOS LAN remote that uses Sony IRCC-IP, REST API, and Wake-on-LAN. It does not require ADB and has been verified with a KD-55X9000H.

Version: **1.3 (10)**

### Features

- Direction pad, OK, Home, Back, volume, mute, and power controls
- Automatic connection recovery and Wake-on-LAN
- Mac text input, copy, and paste into the active TV text field
- First-run Sony BRAVIA discovery with manual IP fallback
- Multiple TV profiles with one active TV at a time
- Per-profile name, model, location, IP address, MAC address, and Keychain PSK
- English and Simplified Chinese UI that follows the macOS preferred language; English is the fallback

### TV setup

Menu names vary by BRAVIA firmware. In the TV network or home-network settings:

1. Enable **Remote Start**.
2. Enable **Simple IP Control**.
3. Select **Pre-Shared Key** authentication.
4. Set a PSK and enter the same value in the Mac app.

The app first tries Sony ScalarWebAPI SSDP/UPnP discovery, then probes the current `/24` subnet through `/sony/system`. Guest networks, AP isolation, or TV standby can block discovery; use manual IP setup in that case.

### Run and build

```zsh
./run.sh
```

```zsh
./build.sh
```

The generated application is `build/Sony BRAVIA Remote.app`. Building from source requires macOS 13 or later and the Apple Swift toolchain. Android Platform Tools are not required.

### Privacy

Each PSK is stored only in the local macOS Keychain. It is not written to source code, configuration files, or Git. The app communicates directly with TVs on the local network and does not require a cloud service.

## Copyright

Copyright © 2026 Zhuchao Li · zhuchao.li@gmail.com. All rights reserved.
