#!/bin/bash
# 绿电直连规划仿真平台 — 后端启动脚本

echo "=========================================="
echo " 绿电直连算电协同规划仿真平台"
echo " Green Power Direct-Connect Planning Platform"
echo "=========================================="

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "❌ 需要 Python 3.8+"
    exit 1
fi

# Install dependencies
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "📦 安装依赖..."
echo "   如默认 PyPI 访问受限，可先设置: export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple"
python3 -m pip install -r "$SCRIPT_DIR/requirements.txt"

# Start server
echo "🚀 启动后端服务 → http://localhost:8000"
echo "📚 API文档 → http://localhost:8000/docs"
echo ""
cd "$SCRIPT_DIR"
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
