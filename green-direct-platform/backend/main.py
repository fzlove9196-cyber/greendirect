"""
绿电直连算电协同规划仿真平台 — 后端服务
FastAPI + 异步任务队列
"""
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn
import asyncio
import uuid
import time
import math
import json
import logging
from datetime import datetime
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field

# 算法核心模块
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from core.province_data import WEATHER_DATA, TARIFF_DATA, PROVINCE_NAMES, list_provinces

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="绿电直连规划仿真平台 API",
    description="面向数据中心绿电直连场景的源网荷储冷算协同优化设计工具",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── 内存存储 ───
projects: Dict[str, dict] = {}
simulation_runs: Dict[str, dict] = {}


# ─── Pydantic Models ───

class ProjectCreate(BaseModel):
    name: str
    region_name: str
    data_year: int = 2025
    province_key: Optional[str] = None
    description: Optional[str] = ""

class ScenarioConfig(BaseModel):
    project_id: str
    scenario_name: str
    scenario_type: str = "S3"          # S1 / S3
    objective_mode: str = "cost"        # cost / carbon
    policy_scenario: str = "A"
    alpha: float = 0.4
    gep_start: float = 0.0
    gep_end: float = 1.0
    gep_step: float = 0.05
    write_dispatch: bool = True
    ramp_weight: float = 0.25
    # device params override
    cap_cost_pv: Optional[float] = None
    cap_cost_wt: Optional[float] = None
    cap_cost_ba: Optional[float] = None
    cap_cost_ct: Optional[float] = None

class SensitivityRequest(BaseModel):
    run_id: str
    variable: str        # ba_cost / pv_cost / wt_cost / grid_price / export_price / alpha
    range_pct: List[float] = [-50, -30, -10, 0, 10, 30, 50]


# ─── Helper ───

def make_gep_targets(start, end, step):
    targets = []
    v = start
    while v <= end + 1e-9:
        targets.append(round(v, 4))
        v += step
    return targets


def run_simulation_sync(run_id: str, project_id: str, scenario: dict):
    """在后台线程中运行优化求解"""
    try:
        simulation_runs[run_id]["status"] = "running"
        simulation_runs[run_id]["started_at"] = datetime.now().isoformat()

        proj = projects[project_id]
        prov_key = proj.get("province_key", "Prov1")

        # 加载气象和电价数据
        wd_raw = WEATHER_DATA[prov_key]
        td_raw = TARIFF_DATA[prov_key]

        import numpy as np
        from core.optimizer import (
            WeatherData, TariffData, OptimizerConfig, solve_region
        )

        wd = WeatherData(
            Tdb=np.array(wd_raw["Tdb"]),
            Twb=np.array(wd_raw["Twb"]),
            S=np.array(wd_raw["S"]),
            vw=np.array(wd_raw["vw"]),
            w=np.array(wd_raw["w"], dtype=float),
            d=np.array(wd_raw["d"]),
            EF=np.array(wd_raw["EF"]),
        )

        td = TariffData(
            price_MWh=np.array(td_raw["price_kwh"]) * 1000,    # ¥/kWh → ¥/MWh
            fee_MW=float(td_raw["cap_fee_kw_mon"]) * 1000,     # ¥/kW/月 → ¥/MW/月
            export_MWh=float(td_raw["export_price_kwh"]) * 1000,
        )

        gep_targets = make_gep_targets(
            scenario["gep_start"],
            scenario["gep_end"],
            scenario["gep_step"]
        )

        cfg = OptimizerConfig(
            scenario=scenario["scenario_type"],
            objective=scenario["objective_mode"],
            policy=scenario["policy_scenario"],
            alpha=scenario["alpha"],
            gep_targets=gep_targets,
            ramp_weight=scenario.get("ramp_weight", 0.25),
        )

        # device overrides
        if scenario.get("cap_cost_pv"): cfg.cap_cost_pv = scenario["cap_cost_pv"]
        if scenario.get("cap_cost_wt"): cfg.cap_cost_wt = scenario["cap_cost_wt"]
        if scenario.get("cap_cost_ba"): cfg.cap_cost_ba = scenario["cap_cost_ba"]
        if scenario.get("cap_cost_ct"): cfg.cap_cost_ct = scenario["cap_cost_ct"]

        total = len(gep_targets)
        completed = 0

        def progress_cb(z, n, s_target):
            nonlocal completed
            completed = z
            simulation_runs[run_id]["progress"] = round(z / n * 100)
            simulation_runs[run_id]["current_gep"] = s_target

        results, best_points = solve_region(
            wd, td, cfg,
            write_dispatch=scenario.get("write_dispatch", True),
            progress_callback=progress_cb,
        )

        # Serialize results
        scan_result = []
        for r in results:
            scan_result.append({
                "z": r.z,
                "gep_target": r.GEP_target,
                "gep_actual": r.GEP_actual,
                "feasible": r.feasible,
                "cpv": r.Cpv,
                "cwt": r.Cwt,
                "cba": r.Cba,
                "cct": r.Cct,
                "lcoe_total": None if math.isnan(r.LCOE_total) else r.LCOE_total,
                "lcoe_it": None if math.isnan(r.LCOE_IT) else r.LCOE_IT,
                "carbon_total": r.Carbon_total_kgCO2e,
                "pue": None if math.isnan(r.PUE) else r.PUE,
                "cue": None if math.isnan(r.CUE) else r.CUE,
                "curt_rate": r.CurtRate,
                "grid_annual": r.grid_annual,
                "export_annual": r.export_annual,
                "capex_total": r.CAPEX_total,
                "opex_total": r.OPEX_total,
                "cost_pv": r.Cost_PV,
                "cost_wt": r.Cost_WT,
                "cost_ba": r.Cost_BA,
                "cost_ct": r.Cost_CT,
                "cost_line": r.Cost_Line,
                "grid_energy_cost": r.Grid_energy_cost,
                "export_revenue": r.ExportRevenue,
                "green_hours": r.GreenHours_actual,
                "green_hour_share": r.GreenHourShare_actual,
                "share_pv": r.Share_PV,
                "share_wt": r.Share_WT,
                "share_ba": r.Share_BA,
                "share_ct": r.Share_CT,
                "share_grid": r.Share_Grid,
                "solve_time": r.solve_time,
                # dispatch
                "dispatch": {
                    "pg": r.Pg_mat.tolist() if r.Pg_mat is not None else None,
                    "ppv": r.Ppv_use_mat.tolist() if r.Ppv_use_mat is not None else None,
                    "pwt": r.Pwt_use_mat.tolist() if r.Pwt_use_mat is not None else None,
                    "pba_c": r.Pba_c_mat.tolist() if r.Pba_c_mat is not None else None,
                    "pba_d": r.Pba_d_mat.tolist() if r.Pba_d_mat is not None else None,
                    "eba": r.Eba_mat.tolist() if r.Eba_mat is not None else None,
                    "ld_it": r.Ld_IT_mat.tolist() if r.Ld_IT_mat is not None else None,
                } if r.feasible else None,
            })

        simulation_runs[run_id].update({
            "status": "completed",
            "finished_at": datetime.now().isoformat(),
            "progress": 100,
            "scan_result": scan_result,
            "best_points": best_points,
            "gep_targets": gep_targets,
        })

    except Exception as e:
        logger.exception(f"Simulation {run_id} failed")
        simulation_runs[run_id].update({
            "status": "failed",
            "finished_at": datetime.now().isoformat(),
            "error_message": str(e),
        })


# ─── API Routes ───

@app.get("/api/provinces")
def get_provinces():
    """获取所有可选省份"""
    return [
        {"key": k, "name": v}
        for k, v in PROVINCE_NAMES.items()
        if k in WEATHER_DATA
    ]


@app.post("/api/projects")
def create_project(body: ProjectCreate):
    project_id = str(uuid.uuid4())[:8]
    proj = {
        "id": project_id,
        "name": body.name,
        "region_name": body.region_name,
        "data_year": body.data_year,
        "province_key": body.province_key or "Prov1",
        "description": body.description,
        "created_at": datetime.now().isoformat(),
        "scenarios": [],
    }
    projects[project_id] = proj
    return proj


@app.get("/api/projects")
def list_projects():
    return list(projects.values())


@app.get("/api/projects/{project_id}")
def get_project(project_id: str):
    if project_id not in projects:
        raise HTTPException(404, "Project not found")
    return projects[project_id]


@app.post("/api/scenarios/run")
def create_and_run(body: ScenarioConfig, background_tasks: BackgroundTasks):
    if body.project_id not in projects:
        raise HTTPException(404, "Project not found")

    scenario_id = str(uuid.uuid4())[:8]
    run_id = str(uuid.uuid4())[:8]

    scenario = body.dict()
    scenario["id"] = scenario_id

    projects[body.project_id]["scenarios"].append(scenario_id)

    simulation_runs[run_id] = {
        "id": run_id,
        "scenario_id": scenario_id,
        "project_id": body.project_id,
        "scenario_name": body.scenario_name,
        "scenario_type": body.scenario_type,
        "status": "queued",
        "progress": 0,
        "current_gep": None,
        "created_at": datetime.now().isoformat(),
        "started_at": None,
        "finished_at": None,
        "error_message": None,
        "scan_result": None,
        "best_points": None,
    }

    background_tasks.add_task(run_simulation_sync, run_id, body.project_id, scenario)
    return {"run_id": run_id, "scenario_id": scenario_id}


@app.get("/api/runs/{run_id}/status")
def get_run_status(run_id: str):
    if run_id not in simulation_runs:
        raise HTTPException(404, "Run not found")
    r = simulation_runs[run_id]
    return {
        "id": r["id"],
        "status": r["status"],
        "progress": r["progress"],
        "current_gep": r.get("current_gep"),
        "started_at": r.get("started_at"),
        "finished_at": r.get("finished_at"),
        "error_message": r.get("error_message"),
    }


@app.get("/api/runs/{run_id}/results")
def get_run_results(run_id: str):
    if run_id not in simulation_runs:
        raise HTTPException(404, "Run not found")
    r = simulation_runs[run_id]
    if r["status"] != "completed":
        raise HTTPException(400, f"Run status: {r['status']}")
    return {
        "run_id": run_id,
        "scan_result": r["scan_result"],
        "best_points": r["best_points"],
    }


@app.get("/api/runs/{run_id}/dispatch")
def get_dispatch(run_id: str, gep_index: int = 0):
    """获取指定GEP点的典型日调度明细"""
    if run_id not in simulation_runs:
        raise HTTPException(404, "Run not found")
    r = simulation_runs[run_id]
    if r["status"] != "completed":
        raise HTTPException(400, "Not completed")
    scan = r.get("scan_result", [])
    if gep_index >= len(scan):
        raise HTTPException(400, "Index out of range")
    return scan[gep_index].get("dispatch")


@app.get("/api/runs")
def list_runs(project_id: Optional[str] = None):
    runs = list(simulation_runs.values())
    if project_id:
        runs = [r for r in runs if r.get("project_id") == project_id]
    return [{k: v for k, v in r.items() if k not in ("scan_result", "best_points")} for r in runs]


@app.post("/api/sensitivity")
def run_sensitivity(body: SensitivityRequest):
    """基于已有结果做敏感性扫描（快速计算，不重新求解）"""
    if body.run_id not in simulation_runs:
        raise HTTPException(404, "Run not found")
    r = simulation_runs[body.run_id]
    if r["status"] != "completed":
        raise HTTPException(400, "Run not completed")

    best = r["best_points"]
    base_lcoe = best.get("Knee_LCOE_total", 0.66)
    base_capex = sum(
        s.get("capex_total", 0) for s in r["scan_result"]
        if s.get("feasible") and abs(s.get("gep_actual", 0) - best.get("Knee_GEP", 0.8)) < 0.05
    ) / max(1, sum(1 for s in r["scan_result"] if s.get("feasible") and abs(s.get("gep_actual", 0) - best.get("Knee_GEP", 0.8)) < 0.05))

    results = []
    for pct in body.range_pct:
        factor = 1 + pct / 100
        # Simplified sensitivity: linear impact on LCOE
        impact_map = {
            "ba_cost": 0.25,    # 电池成本对LCOE的弹性
            "pv_cost": 0.15,
            "wt_cost": 0.12,
            "grid_price": 0.20,
            "export_price": -0.08,
            "alpha": -0.05,
        }
        elasticity = impact_map.get(body.variable, 0.1)
        lcoe_change_pct = pct * elasticity / 100
        results.append({
            "change_pct": pct,
            "lcoe_total": round(base_lcoe * (1 + lcoe_change_pct), 4),
            "lcoe_change_pct": round(lcoe_change_pct * 100, 2),
        })

    return {"variable": body.variable, "base_lcoe": base_lcoe, "results": results}


@app.get("/api/health")
def health():
    return {"status": "ok", "time": datetime.now().isoformat()}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
