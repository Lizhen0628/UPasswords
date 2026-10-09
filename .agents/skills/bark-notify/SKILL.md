---
name: bark-notify
description: 通过 Bark 向用户的 iPhone 发送推送通知。当长任务完成(构建/部署/测试套件跑完)、需要用户立即操作(真机验收、输密码、确认弹窗)、任务失败需要用户介入,或用户明确要求"完成后通知我"时使用。读取 ~/.zshrc 中的 BARK_KEY/BARK_BASE_URL/MACHINE_NAME。
---

# Bark 推送通知

向用户的 iPhone 推送 Bark 通知。凭证在 `~/.zshrc`(`BARK_KEY`/`BARK_BASE_URL`/`MACHINE_NAME`),
本目录的 `notify.sh` 会自动读取(当前 shell 没有这些环境变量时从 .zshrc 提取)。

## 用法

```bash
<skill_dir>/notify.sh "标题" "正文" [分组]
```

- 分组默认 `UPasswords`(Bark App 内按组聚合)
- 标题自动带机器名前缀,如 `[macbook pro 14] 构建完成`
- 成功输出 HTTP 200,失败非零退出;发送失败不要中断主任务,记日志即可

## 何时发通知(克制使用)

**发:**
- 长任务完成:全量构建、四包测试、CI 部署、打包
- 需要用户立即动作:真机验收就绪、需要输密码/点弹窗/插拔数据线
- 阻塞性失败:构建挂、部署挂、凭证失效

**不发:**
- 每条普通进度消息(问答轮次内的事)
- 用户正在连续交互时(几秒内的即时回复)
- 敏感内容:密码、密钥、字段值、库内容(隐私红线与代码库一致)

## 文案规范

- 中文、一行说清结果 + 需要的动作:`iOS 已装到 iPhone,杀掉旧进程重开验收`
- 失败带可定位信息:`CI 失败:xcodebuild iOS 签名错误,日志 /tmp/xx`
