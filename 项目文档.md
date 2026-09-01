# KnowledgeBase-RAG-LLM-System 项目文档

> 本文档面向已部署完成的本地实例（部署路径 `D:\code\RAG`），涵盖项目背景、技术架构、功能实现、项目成果，并在附录中以独立形式详解技术栈的具体用法。

---

## 一、项目背景

### 1.1 项目定位
KnowledgeBase-RAG-LLM-System 是一个**面向本地知识库问答与 RAG（检索增强生成）入门实践**的开源学习项目，源自 Black Horse（黑马）教程。项目以"电商服装智能客服"为业务场景示范，提供从知识上传、向量化存储、语义检索到大模型增强回答的完整闭环，便于学习者快速复现并扩展。

### 1.2 业务场景
项目内置三份示例知识文本（位于 `assets/` 目录），模拟电商客服常见咨询：
- `尺码推荐.txt` — 身高体重→尺码对照表
- `洗涤养护.txt` — 四季服装材质洗涤养护指南
- `颜色推荐.txt` — 肤色/场合/体型与服装颜色搭配

用户可按自身业务替换为任意 txt 文本（产品手册、FAQ、规章制度等），系统即变为该领域的智能问答客服。

### 1.3 核心价值
- **检索增强**：先从知识库召回相关片段，再交给大模型组织回答，降低幻觉
- **知识可控**：知识存储在本地 Chroma 向量库，不依赖模型训练
- **成本低**：仅调用通义千问 API（按量计费），无需自建大模型
- **可扩展**：项目结构清晰，易于向多模态、Rerank、Agent 演进

---

## 二、技术架构

### 2.1 分层架构

```text
┌─────────────────────────────────────────────┐
│  Web 交互层（Streamlit）                      │
│  app_upload.py   ·   app_chat.py             │
├─────────────────────────────────────────────┤
│  业务服务层                                   │
│  KnowledgeBaseService  ·  RagService         │
├─────────────────────────────────────────────┤
│  RAG 编排层（LangChain LCEL 链）              │
│  Retriever → Prompt → LLM → OutputParser     │
│  + RunnableWithMessageHistory                 │
├──────────────┬──────────────────────────────┤
│  数据层       │  模型层                       │
│  Chroma 向量库│  DashScope（通义千问）        │
│  文件历史存储 │  qwen3-max · text-embedding-v4│
└──────────────┴──────────────────────────────┘
```

### 2.2 数据流转

**写入路径（知识入库）：**
```text
txt 文件 → Streamlit file_uploader → getvalue().decode("utf-8")
  → MD5 去重检查 → (>1000字) RecursiveCharacterTextSplitter 切分
  → DashScopeEmbeddings 向量化 → Chroma.add_texts(含metadata) → MD5 落盘
```

**查询路径（RAG 问答）：**
```text
用户输入 → chain.stream
  → 并行：RunnablePassthrough 透传 input
         RunnableLambda(format_for_retriever) | retriever | format_document 组装 context
  → format_for_prompt_template 重整为 {input, context, history}
  → ChatPromptTemplate 填充模板
  → ChatTongyi 生成 → StrOutputParser
  → 流式 chunk → Streamlit write_stream → 页面 + session_state 缓存
  → RunnableWithMessageHistory 自动写历史到 ./chat_history/user_001
```

### 2.3 模块职责

| 文件 | 职责 |
|------|------|
| `app_upload.py` | Streamlit 上传页：文件选择、信息展示、调用入库 |
| `app_chat.py` | Streamlit 聊天页：历史消息渲染、流式输出、session_state 管理 |
| `knowledge_base.py` | 知识库服务：MD5 去重、文本切分、写入 Chroma |
| `rag.py` | RAG 链组装：检索→提示→模型→解析，并挂载历史 |
| `vector_stores.py` | 向量库封装：Chroma 实例 + 检索器获取 |
| `file_history_store.py` | 会话历史：基于 JSON 文件的 BaseChatMessageHistory 实现 |
| `config_data.py` | 全局配置：模型名、路径、切分参数、检索 k 值 |

---

## 三、功能实现

### 3.1 知识库上传

**入口**：`app_upload.py` — `st.file_uploader` 接收单个 txt 文件，`getvalue().decode("utf-8")` 提取文本，调用 `KnowledgeBaseService.upload_by_str(text, file_name)`。

**核心逻辑**（`knowledge_base.py`）：
1. **MD5 去重**：对全文计算 MD5，查 `./md5.text` 记录；命中则返回 `[Repeat]`，避免重复入库
2. **条件切分**：文本 > 1000 字时用 `RecursiveCharacterTextSplitter`（chunk_size=1000, overlap=100）切分；否则整段入库
3. **元数据附加**：每块附 `source(文件名)/create_time/操作者` 三项 metadata
4. **向量化入库**：`Chroma.add_texts` 自动调用 `text-embedding-v4` 嵌入后写入 `./chroma_db`

### 3.2 RAG 问答

**入口**：`app_chat.py` — `RagService` 实例存入 `session_state` 避免重建；用户输入后调用 `chain.stream` 流式输出，`capture` 生成器同时缓存 chunk 到列表，最后拼回完整回答存入 `session_state["message"]`。

**链构造**（`rag.py` LCEL 语法）：
```python
chain = (
    {"input": RunnablePassthrough(),
     "context": RunnableLambda(format_for_retriever) | retriever | format_document}
) | RunnableLambda(format_for_prompt_template) | self.prompt_template | print_prompt | self.chat_model | StrOutputParser()
```
- 并行字典：`input` 透传，`context` 经检索→格式化
- `format_for_prompt_template` 把嵌套 dict 压平成 `{input, context, history}` 喂给模板
- `print_prompt` 调试钩子，打印最终提示词到终端
- 外层 `RunnableWithMessageHistory` 包裹，自动读写会话历史

**提示词模板**（`rag.py` 第 30 行）：
单条 system（含 `{context}` 占位）+ `MessagesPlaceholder("history")` + user `{input}` 三段式。

### 3.3 向量存储与检索

`vector_stores.py` — 持久化 Chroma（`collection_name="rag"`, `persist_directory="./chroma_db"`），`get_retriever` 返回检索器，`search_kwargs={"k": 1}` 表示每次只召回最相似的 1 条文档。上传服务与问答服务指向同一持久化目录，故上传后立即可问答。

### 3.4 会话历史持久化

`file_history_store.py` — 自定义 `FileChatMessageHistory` 继承 `BaseChatMessageHistory`：
- `add_messages`：合并新旧消息，`message_to_dict` 序列化为 JSON 写入 `./chat_history/{session_id}`
- `messages`：读取 JSON，`messages_from_dict` 反序列化为消息对象；容错文件不存在/损坏返回空列表
- `get_history(session_id)` 工厂函数供 `RunnableWithMessageHistory` 调用

### 3.5 配置中心

`config_data.py` 集中管理：

| 参数 | 值 | 说明 |
|------|----|------|
| collection_name | `rag` | Chroma 表名 |
| persist_directory | `./chroma_db` | 向量库本地目录 |
| chunk_size / overlap | 1000 / 100 | 切分尺寸/重叠 |
| separators | `\n\n \n . ! ? 。 ！ ？ 空格` | 分割符优先级 |
| similarity_threshold | 1 | 检索召回 k 值 |
| embedding_model_name | `text-embedding-v4` | 嵌入模型 |
| chat_model_name | `qwen3-max` | 对话模型 |
| session_id | `user_001` | 会话标识 |

### 3.6 本地部署适配（部署期间所做调整）

为保证项目在本地（Windows + Anaconda rag 环境）正常运行，做了以下适配，均不改变业务逻辑：

| 文件 | 调整 | 原因 |
|------|------|------|
| `config_data.py` 顶部 | 加入 `load_dotenv()` | 自动从 `.env` 读取 `DASHSCOPE_API_KEY`，免手动设系统环境变量 |
| `.env` | 新建，存 API Key | 密钥与代码分离，已加入 `.gitignore` |
| `rag.py` 第 4 行 | 导入改为 `from langchain_core.runnables.history import RunnableWithMessageHistory` | 新版 langchain-core 将该类移至子模块，旧路径报 ImportError |
| `rag.py` 第 30 行 | 两条 system 消息合并为一条 | ChatTongyi 限制最多一条 system，否则抛 ValueError |
| `requirements.txt` | 锁定兼容版本区间 | 规避 numpy 2.x、langchain 0.2+ 兼容性问题 |
| `~/.streamlit/credentials.toml` | email 留空 | 跳过 Streamlit 首次运行的邮箱欢迎提示 |

---

## 四、项目成果

### 4.1 部署成果
- 项目克隆并部署至 `D:\code\RAG`
- 专用 conda 环境 `rag`（Python 3.11，依赖经清华镜像安装）
- PyCharm 项目配置就绪（`.idea/` + 两个运行配置 `RAG-Chat` / `RAG-Upload`）
- 一键启动脚本 `run_chat.bat` / `run_upload.bat`

### 4.2 功能验证（全通过）

| # | 功能 | 结果 |
|---|------|------|
| 1 | `.env` API Key 加载 | ✅ `load_dotenv` 正确读入 |
| 2 | 知识库上传 + MD5 去重 | ✅ 返回 `[Success]`，重复内容返回 `[Repeat]` |
| 3 | 向量检索 | ✅ 召回命中测试文档 |
| 4 | RAG 链端到端（通义千问） | ✅ 检索+生成+解析全通 |
| 5 | 会话历史持久化 | ✅ 跨轮对话上下文正确注入 |
| 6 | Streamlit 上传/问答服务 | ✅ HTTP 200，端口 8501 / 8502 |

### 4.3 端到端测试证据
自检脚本上传测试文本（含标记 `TEST-2026-RAG`）→ 提问"测试编号是多少？" → 模型回答"测试编号是 TEST-2026-RAG。"——证明 **上传→向量化→检索→大模型增强回答** 全链路打通。

### 4.4 局限与优化方向
- 检索 k=1 偏保守，可调大并加 Rerank 提升召回质量
- 单 system 提示词较简单，可引入 Few-shot 示例
- 文件历史存储为单用户 JSON，多用户场景需扩展 session 管理
- 仅支持 txt，可加 pypdf / python-docx 扩展多模态
- 长期演进：Chroma→FAISS、单模型→多模型、RAG→Agent

---
---

# 附录 · 技术栈详解

> 以下内容为各技术组件的**具体用法说明**，以独立条目形式编排，与正文叙述区分，供深入理解与二次开发参考。

### Streamlit
- **是什么**：Python 数据应用 Web 框架，无需写 HTML/JS 即可生成网页
- **本项目用法**：
  - `app_upload.py`：`st.title` 标题、`st.file_uploader` 文件上传、`st.spinner` 加载动画、`st.write` 输出结果
  - `app_chat.py`：`st.chat_message("user"/"assistant")` 聊天气泡、`.write_stream()` 流式渲染、`st.session_state` 跨脚本重跑保持状态
- **运行机制**：页面任意元素变化，整个脚本从头重跑一遍，故用 `session_state` 维持对象与历史

### LangChain（LCEL 链式编排）
- **是什么**：LLM 应用编排框架，LCEL（LangChain Expression Language）用 `|` 管道串联可运行单元
- **本项目用法**（`rag.py`）：用 `|` 把"并行字典→格式化→提示模板→模型→输出解析"串成链
  - `RunnablePassthrough`：透传输入，用于并行分支保留原值
  - `RunnableLambda`：把普通函数包装成可运行单元
  - `StrOutputParser`：把模型输出 AIMessage 提取为纯字符串
- **包结构**：`langchain-core`（运行时/消息体）+ `langchain-community`（通义千问/嵌入封装）+ `langchain-chroma`（向量库集成）+ `langchain-text-splitters`（分割器）

### Chroma 向量数据库
- **是什么**：轻量级开源向量库，支持本地持久化
- **本项目用法**（`vector_stores.py` / `knowledge_base.py`）：
  - `Chroma(collection_name, embedding_function, persist_directory)` 建库
  - `add_texts(texts, metadatas)`：自动嵌入并写入，附元数据
  - `as_retriever(search_kwargs={"k":1})`：转为 LangChain 检索器，按语义相似度召回
- **存储位置**：`./chroma_db`（SQLite + parquet，跨服务共享同一库即可共用知识）

### DashScope / 通义千问
- **是什么**：阿里云大模型服务平台，提供 qwen 系列对话模型与 embedding 模型
- **本项目用法**：
  - `ChatTongyi(model="qwen3-max")`：对话模型，支持流式 `.stream()`
  - `DashScopeEmbeddings(model="text-embedding-v4")`：文本嵌入，把文字转为向量供 Chroma 检索
  - 通过 `DASHSCOPE_API_KEY` 鉴权（本项目从 `.env` 读取）
- **调用链**：上传时嵌入入库；问答时检索→提示→模型生成

### RecursiveCharacterTextSplitter
- **是什么**：LangChain 文本分割器，按分隔符优先级递归切分，尽量保持语义完整
- **本项目用法**（`knowledge_base.py` 第 56 行）：`chunk_size=1000, chunk_overlap=100`，分隔符优先级 `\n\n > \n > . > ! > ? > 。> ！> ？> 空格`。>1000 字才切，短文本整段入库

### RunnableWithMessageHistory
- **是什么**：LangChain 自动管理对话历史的链装饰器
- **本项目用法**（`rag.py` 第 75 行）：包裹 RAG 链，`input_messages_key="input"`（从输入取问题）、`history_messages_key="history"`（注入到提示模板的 history 占位）、`get_history` 工厂返回 `FileChatMessageHistory`。每次调用自动读写历史，无需手动管理

### FileChatMessageHistory
- **是什么**：本项目自定义的文件式历史存储，继承 `BaseChatMessageHistory`
- **本项目用法**（`file_history_store.py`）：每个 session 一个 JSON 文件（`./chat_history/user_001`），存 `list[dict]`；`message_to_dict` / `messages_from_dict` 做序列化

### python-dotenv
- **是什么**：从 `.env` 文件加载环境变量到 `os.environ`
- **本项目用法**（`config_data.py` 第 2 行）：`load_dotenv()` 在配置模块顶部执行，后续 `os.environ["DASHSCOPE_API_KEY"]` 即可取到 `.env` 里的值，避免硬编码或手动设系统变量

### MD5 去重机制
- **是什么**：用 hashlib 对文本算 32 位十六进制摘要，作为内容指纹
- **本项目用法**（`knowledge_base.py` 第 12-43 行）：`get_string_md5` 算摘要 → `check_md5` 查 `./md5.text` 是否已存 → 命中返回 `[Repeat]` 跳过 → 入库后 `save_md5` 追加记录
- **优缺点**：快、实现简单，适合内容级去重；但 MD5 已不适用于安全加密（项目仅用于去重无妨）

### PyCharm 运行配置
- **是什么**：IDE 的"如何运行程序"配置
- **本项目用法**（`.idea/runConfigurations/`）：两个配置 `RAG-Chat` / `RAG-Upload`，`SCRIPT_NAME` 指向 rag 环境下的 `streamlit/__main__.py`，`PARAMETERS` 为 `run app_xxx.py --server.port 8xxx`，`IS_MODULE_SDK=true` 跟随项目解释器；绿色 ▶ 一键启动，红色 ⏹ 停止

---

*文档基于本地部署实例生成，配置参数与文件路径均对应 `D:\code\RAG`。*