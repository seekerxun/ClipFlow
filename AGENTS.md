本文件是协作规范的权威来源。

## 开始工作前

- 开始处理任务前，应先阅读 [`README.md`](README.md)，了解项目状态、目录结构和权威文档关系。

- 不要仅根据聊天记录或旧文档推断当前设计；发生冲突时，以 `README.md` 指定的权威文档为准。

## 协作原则

- 默认使用中文交流和写文档。
- 不要为了显得完整而增加硬核字段，遵循“如无必要勿增实体”。
- 设计文档要服务于后续落地，不写纯装饰性概念。
- 碰到口径歧义、权威文档没覆盖的情况，**默认先问，不要自己补成定稿**。暂时需要占位的，明确标注"待确认"，不混进正式口径。
- AI 向仓库所有者要决定或者讨论的时候，不使用只有 AI 之间才懂的简写，尽量不要提出代码细节，比如xxx.js xxx行或者xx属性xx方法之类的。少说行话和术语，除非不好用其他词替代。

## Git 规范

- 遇到较大改动时应及时做一次本地 commit，不需要自动推送。
- 较大改动包括：
  - 多个文件同时修改
  - 单文件大幅重写
  - 变更范围已经影响后续回滚和理解
- Commit message 必须使用中文，允许使用简短中文前缀，例如”文档：”、“开发：”、“测试：”。
- AI 协作者提交时，Author 必须使用下表中自己的名字与邮箱，不得冒用仓库所有者或其他 AI 的身份；不得改写全局或仓库的 `user.name` / `user.email`，只在当次提交指定（例如 `git -c user.name=... -c user.email=... commit`）。
  
  | 身份                    | Author 名字 | Author 邮箱                |
  | --------------------- | --------- | ------------------------ |
  | ChatGPT / GPT / Codex | ChatGPT   | `noreply@openai.com`     |
  | Cursor / Grok         | Cursor    | `cursoragent@cursor.com` |
  | Claude                | Claude    | `noreply@anthropic.com`  |
- 满足以上条件时直接本地 commit，不需要每次都先询问用户确认；push 仍需用户另行明确同意。
- **每次提交前把构建号加 1。** 改 `project.yml` 里的 `CURRENT_PROJECT_VERSION`（应用的构建号，对应 Xcode 的 Build），然后跑 `xcodegen generate`。对外显示的版本号 `MARKETING_VERSION`（现在是 0.1.0）只在真正发新版本时改，不要每次提交都动。

## 编码与行尾规则

- 中文文档和源码文件统一使用 UTF-8 保存。
- Markdown、TypeScript、JavaScript、JSON、HTML、CSS、YAML 文件统一使用 LF 行尾；PowerShell 脚本可以使用 CRLF。
- Windows 侧 AI 协作者混写文件后，交接前优先运行 `./tools/check-text-encoding.ps1`，确认 UTF-8 合法、无 NUL 空字节、无异常 CRLF。
