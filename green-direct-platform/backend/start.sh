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
echo "📦 安装依赖..."
pip install fastapi uvicorn pydantic numpy pulp python-multipart -q

# Start server
echo "🚀 启动后端服务 → http://localhost:8000"
echo "📚 API文档 → http://localhost:8000/docs"
echo ""
cd "$(dirname "$0")"
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
