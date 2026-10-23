# Sony Remote

Sony KD-55X9000H 的 macOS 原生图形遥控器，通过已授权的 ADB TCP 连接 `192.168.6.147:5555`。

## 运行

双击 `build/Sony Remote.app`，或在终端执行：

```zsh
./run.sh
```

重新构建：

```zsh
./build.sh
```

应用支持方向键、OK、Home、Back、音量加减、静音、电源，以及断线自动重连和手动重连。键盘方向键、Return、Esc、H 也可操作。

依赖：macOS 13 或更高版本、Swift、Android Platform Tools（`adb`）。
