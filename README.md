# 绿电直连算电协同规划仿真平台

> 面向数据中心绿电直连场景的源网荷储冷算协同优化设计工具

## 系统架构

```
green-direct/
├── backend/                    # Python FastAPI 后端
│   ├── main.py                 # API 服务入口
│   ├── requirements.txt        # Python 依赖
│   ├── start.sh               # 一键启动脚本
│   └── core/
│       ├── optimizer.py        # MILP 优化算法（GEP扫描）
│       └── province_data.py    # 31省气象+电价真实数据
└── frontend/
    └── index.html              # 完整单页前端应用（无需构建）
```

## 快速启动

### 1. 启动后端

```bash
cd backend
bash start.sh
# 或手动安装并运行:
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

后端服务：http://localhost:8000  
API文档（Swagger）：http://localhost:8000/docs

### 2. 打开前端

直接在浏览器打开 `frontend/index.html`，或通过静态文件服务器：

```bash
cd frontend
python -m http.server 3000
# 浏览器访问 http://localhost:3000
```

## 核心功能

| 模块 | 功能 |
|------|------|
| 🏠 首页总览 | 项目驾驶舱，推荐方案快速查看 |
| 📁 项目管理 | 创建项目，选择31省真实数据 |
| ⚙️ 场景配置 | S1/S3方案、GEP扫描、α参数配置 |
| 🌤️ 资源诊断 | 太阳能/风能资源评分、电网碳因子分析 |
| 🚀 优化仿真 | 提交MILP求解任务，实时进度追踪 |
| 📊 结果分析 | GEP-LCOE曲线、容量配置、扫描详表 |
| ⏱️ 典型日调度 | 24小时电力平衡、电池SOC可视化 |
| 🔄 方案对比 | S1 vs S3 LCOE/弃电率对比 |
| 💰 投资决策 | CAPEX/OPEX/LCOE/回收期/成本构成 |
| 📉 敏感性分析 | 龙卷风图、关键参数LCOE弹性 |

## 算法模型（optimizer.py）

基于 PuLP/Gurobi 的 MILP 混合整数线性规划：

- **S1方案**：风光 + 电池储能（含 CRF 年化成本、GEP 约束）
- **S3方案**：风光 + 电池 + 蓄冷 + IT 算力时间转移（α参数）
- **GEP扫描**：对 0%→100% 绿电占比逐档求解，识别 LCOE 拐点
- **目标函数**：最小化年化总成本（含 CAPEX/OPEX/电费/弃电/容量电费）
- **约束**：电力平衡、GEP比例、储能SOC、弃电率、上网电价比

## API 接口

```
GET  /api/provinces                  # 获取31省列表
POST /api/projects                   # 创建项目
GET  /api/projects                   # 项目列表
POST /api/scenarios/run              # 创建场景并启动仿真
GET  /api/runs/{id}/status           # 查询仿真状态（轮询）
GET  /api/runs/{id}/results          # 获取完整结果
GET  /api/runs/{id}/dispatch         # 获取调度明细
POST /api/sensitivity                # 敏感性分析
GET  /api/health                     # 健康检查
```

## 数据说明

- **31省气象数据**：干球/湿球温度、太阳辐照度、风速，6个典型日 × 24小时
- **电价数据**：分时电价（¥/kWh）、容量电费（¥/kW/月）、上网电价
- **碳因子**：电网排放因子（kgCO₂/kWh），随时段和典型日变化

## 技术栈

- **后端**：Python + FastAPI + PuLP（CBC求解器）
- **前端**：原生HTML/CSS/JS + Chart.js（无需Node.js/框架）
- **算法**：MILP（Mixed Integer Linear Programming）
- **数据**：NumPy 矩阵运算，31省真实气象电价数据库

## 性能参考

| 配置 | GEP点数 | 求解时间 |
|------|--------|--------|
| S1 · 5档 GEP | 5 | ~2分钟 |
| S1 · 21档 GEP | 21 | ~8分钟 |
| S3 · 21档 GEP | 21 | ~15分钟 |

（使用 CBC 开源求解器，Gurobi 可提速约5-10倍）
