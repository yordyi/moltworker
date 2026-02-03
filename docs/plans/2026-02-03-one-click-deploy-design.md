# One-Click Deploy Script Design

**Date:** 2026-02-03
**Status:** Implemented

## Overview

为小白用户设计的一键部署脚本，通过交互式引导完成 OpenClaw (Moltbot) 在 Cloudflare Workers 上的部署。

## Design Decisions

### 1. 平台支持
- **选择**: 仅 macOS/Linux (Bash 脚本)
- **原因**: 覆盖大多数开发者，实现最简单

### 2. 配置方式
- **选择**: 智能配置
- **行为**: 先配置必需项 (API Key, Gateway Token, CF Access)，最后询问是否配置可选项 (Telegram, Discord, R2)

### 3. 认证方式
- **选择**: 双模式
- **快速体验**: DEV_MODE=true，跳过 CF Access 配置
- **完整安全**: 引导用户配置 Cloudflare Access

### 4. 部署方式
- **选择**: GitHub Actions
- **原因**:
  - `gh` CLI 可完全自动化
  - 无需本地 Docker
  - 可添加 upstream sync 保持更新

## Script Flow

```
环境检查 → Fork/Clone → GitHub Actions → 收集配置 →
设置 Secrets → 触发部署 → 选择模式 → 可选配置 → 完成
```

## Files Created

- `scripts/deploy.sh` - 主部署脚本 (772 行)
- `README.md` - 添加一键部署说明

## Usage

```bash
# 远程执行
curl -fsSL https://raw.githubusercontent.com/cloudflare/moltworker/main/scripts/deploy.sh | bash

# 本地执行
chmod +x scripts/deploy.sh && ./scripts/deploy.sh
```

## Requirements

- GitHub 账号 + GitHub CLI (`gh`)
- Cloudflare 账号 (Workers Paid, $5/月)
- Node.js
- Anthropic API Key 或 AI Gateway

## Future Improvements

- [ ] 添加 Windows PowerShell 版本
- [ ] 支持自定义 Worker 名称
- [ ] 添加配置文件导出/导入
- [ ] 添加健康检查和故障诊断
