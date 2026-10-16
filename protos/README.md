# 弹幕 Protobuf 源文件

`dm.proto` / `dmView.proto` 是 `ATV-Bilibili/Request/dm.pb.swift`、`dmView.pb.swift` 的**源头**。
2026-10 从旧版 protoc-gen-swift 的生成代码无损还原（字段号/名称/类型/注释逐一比对），并用
B 站线上真实二进制响应做过 `protoc --decode` 对拍验证（seg 320 条弹幕 + view 全嵌套字段精确命中）。

## 为什么放在仓库里

此前仓库只有生成产物没有 .proto 源，导致旧生成代码对着 SwiftProtobuf 1.35.1 运行时报 28 条
「请用当前版本插件重新生成」弃用警告却无法重生成。现在源文件入库，随时可重生成。

## 重新生成步骤

插件版本必须与 App 链接的 SwiftProtobuf 运行时（见 `Package.resolved`，当前 1.35.1）**严格一致**：

```bash
# 1. protoc（brew 装不动时可直接下 GitHub Releases 的 osx-aarch_64 zip）
brew install protobuf

# 2. protoc-gen-swift 从 Xcode 解析出的 swift-protobuf checkout 编译，保证版本匹配
#    （checkout 路径在 ~/Library/Developer/Xcode/DerivedData/<工程>-*/SourcePackages/checkouts/swift-protobuf）
cp -R <checkout>/swift-protobuf /tmp/spb && cd /tmp/spb
swift build -c release --product protoc-gen-swift

# 3. 生成并覆盖
protoc -I protos \
  --plugin=protoc-gen-swift=/tmp/spb/.build/release/protoc-gen-swift \
  --swift_out=ATV-Bilibili/Request protos/dm.proto protos/dmView.proto
```

## 对拍验证（改动 proto 后必做）

```bash
# seg: 需要 x/v2/dm/list/seg.so 这个新端点(旧 x/v2/dm/seg.so 已被风控拦截, 返回 HTML)
curl -s 'https://api.bilibili.com/x/v2/dm/list/seg.so?type=1&oid=<cid>&segment_index=1' \
  -H 'User-Agent: Mozilla/5.0' -H 'Referer: https://www.bilibili.com' > /tmp/seg.bin
protoc -I protos --decode=DmSegMobileReply dm.proto < /tmp/seg.bin

curl -s 'https://api.bilibili.com/x/v2/dm/web/view?type=1&oid=<cid>' \
  -H 'User-Agent: Mozilla/5.0' > /tmp/view.bin
protoc -I protos --decode=DmWebViewReply dmView.proto < /tmp/view.bin
```

能解出 `elems`/`commandDms` 等字段即为对拍通过。响应里出现纯数字字段号（如 `15: 3`）是
B 站新增而我们未声明的字段，走 unknownFields 保留，无需处理。
