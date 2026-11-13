# 一页待办 · OnePage

使用 SwiftUI 开发的简约待办应用，包含 macOS 应用和 iOS 工程。

支持任务管理、日期选择、任务分组与日历视图。macOS 界面采用侧栏、任务列表和详情编辑区布局。

## macOS

需要 macOS 14 或更新版本，以及支持 Swift 6 的 Xcode / Swift 工具链。

```sh
bash build.sh
open build/一页待办.app
```

默认构建使用本地临时签名。CloudKit 构建需要额外配置开发者签名、容器权限及描述文件；相关配置见 `build.sh`。

## iOS

使用 Xcode 打开 `iOS/OnePageiOS.xcodeproj`，选择 `OnePageiOS` scheme 和模拟器或设备运行。真机运行需要配置自己的开发者签名。

## 目录

- `Sources/OnePage`：macOS 界面与共享数据逻辑
- `Assets`：macOS 应用图标
- `Tests`：Swift Package 测试
- `iOS`：iOS 工程、资源与测试

仓库不包含本地任务数据、编译产物和历史备份。
