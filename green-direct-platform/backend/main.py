"""
绿电直连算电协同规划仿真平台 — 后端服务
FastAPI + 异步任务队列
"""
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import uuid
import math
import logging
from datetime import datetime
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field, field_validator

# 算法核心模块
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from core.province_data import WEATHER_DATA, TARIFF_DATA, PROVINCE_NAMES

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

class WeatherInfo(BaseModel):
    temp_dry: List[List[float]] = Field(..., description="24×6 干球温度 degC")
    temp_wet: List[List[float]] = Field(..., description="24×6 湿球温度 degC")
    solar_irradiance: List[List[float]] = Field(..., description="24×6 太阳辐照度 W/m2")
    wind_speed: List[List[float]] = Field(..., description="24×6 风速 m/s")
    typical_day_weight: List[float] = Field(..., description="6 个典型日权重，建议合计365")
    grid_carbon_factor: List[List[float]] = Field(..., description="24×6 电网碳因子 kgCO2e/kWh")


class TariffInfo(BaseModel):
    grid_price: List[float] = Field(..., description="24小时分时购电价，元/kWh")
    capacity_fee: float = Field(..., description="容量电费，元/kW/月")
    export_price: float = Field(..., description="上网电价，元/kWh")
    currency: str = "CNY"
    tariff_name: Optional[str] = None


class LoadInfo(BaseModel):
    it_load: List[float] = Field(..., description="24小时 IT 基准负荷，MW")
    load_profile: str = Field("raw", description="负荷曲线模式：raw/flat/day_peak/night_bias/dual_peak")
    it_load_cap_s3: float = 500.0
    chiller_cap_multiplier: float = 1.5
    qch_cap_max_s3: float = 750.0
    alpha: Optional[float] = None
    flex_windows: List[int] = Field(default_factory=lambda: [2, 5, 8, 12])


class DataCenterLoadInfo(BaseModel):
    mean_it_load_mw: Optional[float] = Field(None, description="数据中心平均 IT 负荷，MW；未提供24小时曲线时用于生成基准负荷")
    it_load: Optional[List[float]] = Field(None, description="24小时 IT 基准负荷曲线，MW；优先级高于 mean_it_load_mw")
    load_profile: str = Field("raw", description="负荷曲线模式：raw/flat/day_peak/night_bias/dual_peak")
    chiller_cap_multiplier: Optional[float] = Field(None, description="制冷机容量倍数，S1/S2 生效")
    it_load_cap_s3: Optional[float] = Field(None, description="S3 优化后 IT 负荷上限，MW")
    qch_cap_max_s3: Optional[float] = Field(None, description="S3 制冷机容量上限，MW_th")
    alpha: Optional[float] = Field(None, description="S3 可时间转移负荷比例")
    flex_windows: Optional[List[int]] = Field(None, description="S3 时间转移窗口集合")


class DeviceParam(BaseModel):
    discount_rate: Optional[float] = None
    life_pv: Optional[int] = None
    life_wt: Optional[int] = None
    life_battery: Optional[int] = None
    life_cold_storage: Optional[int] = None
    life_line: Optional[int] = None
    pv_cap_cost: Optional[float] = None
    pv_om_cost: Optional[float] = None
    wt_cap_cost: Optional[float] = None
    wt_om_cost: Optional[float] = None
    battery_cap_cost: Optional[float] = None
    battery_om_rate: Optional[float] = None
    cold_storage_cap_cost: Optional[float] = None
    cold_storage_om_rate: Optional[float] = None
    line_capex: Optional[float] = None
    pv_cap_max: Optional[float] = None
    wt_cap_max: Optional[float] = None
    battery_cap_max: Optional[float] = None
    cold_storage_cap_max: Optional[float] = None
    battery_efficiency: Optional[float] = None
    battery_power_ratio: Optional[float] = None
    battery_soc_min: Optional[float] = None
    battery_soc_max: Optional[float] = None
    battery_soc_initial: Optional[float] = None
    cold_storage_efficiency: Optional[float] = None
    cold_storage_power_ratio: Optional[float] = None
    cold_storage_soc_min: Optional[float] = None
    cold_storage_soc_max: Optional[float] = None
    cold_storage_soc_initial: Optional[float] = None
    wind_cut_in: Optional[float] = None
    wind_rated: Optional[float] = None
    wind_cut_out: Optional[float] = None
    pv_temp_coeff: Optional[float] = None


class SolverParam(BaseModel):
    solver: str = "auto"
    time_limit: float = 120.0
    mip_gap: float = 5e-3
    verbose: int = 0


class ProjectCreate(BaseModel):
    name: str
    region_name: str
    data_year: int = 2025
    typical_day_count: int = 6
    time_step_hours: float = 1.0
    province_key: Optional[str] = None
    description: Optional[str] = ""
    weather_info: Optional[WeatherInfo] = None
    tariff_info: Optional[TariffInfo] = None
    load_info: Optional[LoadInfo] = None


class ProjectInputUpdate(BaseModel):
    weather_info: Optional[Dict[str, Any]] = None
    tariff_info: Optional[Dict[str, Any]] = None
    load_info: Optional[Dict[str, Any]] = None


class ScenarioConfig(BaseModel):
    project_id: str
    scenario_name: str
    scenario_type: str = "S3"          # S1 / S2 / S3
    objective_mode: str = "cost"        # cost / carbon
    policy_scenario: str = "A"
    alpha: float = 0.4
    flex_windows: List[int] = Field(default_factory=lambda: [2, 5, 8, 12])
    gep_start: float = 0.0
    gep_end: float = 1.0
    gep_step: float = 0.05
    gep_targets: Optional[List[float]] = None
    write_dispatch: bool = True
    ramp_weight: float = 0.25
    curt_rate_limit: float = 0.40
    export_ratio_limit: float = 0.20
    pg_zero_tol: float = 1e-6
    grid_zero_tol_annual: float = 1e-6
    gep_tol: float = 5e-9
    carbon_lexicographic: bool = True
    cost_tie_rel_tol: float = 1e-4
    cost_tie_abs_tol: float = 1e3
    carbon_lex_rel_tol: float = 1e-6
    carbon_lex_abs_tol_kg: float = 1e3
    load_profile: str = "raw"
    it_load_cap_s3: Optional[float] = None
    qch_cap_max_s3: Optional[float] = None
    data_center_load: Optional[DataCenterLoadInfo] = None
    device_param: Optional[DeviceParam] = None
    solver_param: Optional[SolverParam] = None
    # legacy flat device params override
    cap_cost_pv: Optional[float] = None
    cap_cost_wt: Optional[float] = None
    cap_cost_ba: Optional[float] = None
    cap_cost_ct: Optional[float] = None

    @field_validator("scenario_type")
    @classmethod
    def scenario_supported(cls, v):
        if v not in {"S1", "S2", "S3"}:
            raise ValueError("scenario_type must be S1, S2 or S3")
        return v

    @field_validator("objective_mode")
    @classmethod
    def objective_supported(cls, v):
        if v not in {"cost", "carbon"}:
            raise ValueError("objective_mode must be cost or carbon")
        return v

    @field_validator("policy_scenario")
    @classmethod
    def policy_supported(cls, v):
        if v not in {"A", "B", "C"}:
            raise ValueError("policy_scenario must be A, B or C")
        return v

    @field_validator("gep_start", "gep_end", "gep_step", "alpha", "curt_rate_limit", "export_ratio_limit")
    @classmethod
    def non_negative(cls, v):
        if v < 0:
            raise ValueError("value must be non-negative")
        return v

class SensitivityRequest(BaseModel):
    run_id: str
    variable: str        # ba_cost / pv_cost / wt_cost / grid_price / export_price / alpha
    range_pct: List[float] = [-50, -30, -10, 0, 10, 30, 50]


# ─── Helper ───

def make_gep_targets(start, end, step):
    targets = []
    if step <= 0:
        raise ValueError("gep_step must be positive")
    v = start
    while v <= end + 1e-9:
        targets.append(round(v, 4))
        v += step
    return targets


def _as_array_24xn(value, name, np, n_day: Optional[int] = None):
    arr = np.array(value, dtype=float)
    if arr.ndim != 2 or arr.shape[0] != 24:
        raise ValueError(f"{name} must be a 24×N array")
    if n_day is not None and arr.shape[1] != n_day:
        raise ValueError(f"{name} must have {n_day} typical-day columns")
    return arr


def _build_weather_tariff(project: dict, np):
    prov_key = project.get("province_key", "Prov1")
    if prov_key not in WEATHER_DATA or prov_key not in TARIFF_DATA:
        raise ValueError(f"unknown province_key: {prov_key}")

    base_wd = WEATHER_DATA[prov_key]
    base_td = TARIFF_DATA[prov_key]
    wi = project.get("weather_info") or {}
    ti = project.get("tariff_info") or {}
    li = project.get("load_info") or {}

    wd_raw = {
        "Tdb": wi.get("temp_dry", base_wd["Tdb"]),
        "Twb": wi.get("temp_wet", base_wd["Twb"]),
        "S": wi.get("solar_irradiance", base_wd["S"]),
        "vw": wi.get("wind_speed", base_wd["vw"]),
        "w": wi.get("typical_day_weight", base_wd["w"]),
        "d": li.get("it_load", base_wd["d"]),
        "EF": wi.get("grid_carbon_factor", base_wd["EF"]),
    }
    td_raw = {
        "price_kwh": ti.get("grid_price", base_td["price_kwh"]),
        "cap_fee_kw_mon": ti.get("capacity_fee", base_td["cap_fee_kw_mon"]),
        "export_price_kwh": ti.get("export_price", base_td["export_price_kwh"]),
    }

    from core.optimizer import WeatherData, TariffData
    w = np.array(wd_raw["w"], dtype=float)
    if w.ndim != 1 or len(w) == 0:
        raise ValueError("weather_info.typical_day_weight must be a non-empty vector")
    n_day = len(w)
    expected_n_day = int(project.get("typical_day_count") or n_day)
    if expected_n_day != n_day:
        raise ValueError(f"region_info.typical_day_count={expected_n_day} does not match weather_info.typical_day_weight length={n_day}")
    time_step = float(project.get("time_step_hours") or 1.0)
    if abs(time_step - 1.0) > 1e-9:
        raise ValueError("region_info.time_step_hours must be 1.0 in the current 24-hour MATLAB-compatible solver")
    d = np.array(wd_raw["d"], dtype=float)
    if d.shape != (24,):
        raise ValueError("load_info.it_load must contain exactly 24 hourly values")
    price = np.array(td_raw["price_kwh"], dtype=float)
    if price.shape != (24,):
        raise ValueError("tariff_info.grid_price must contain exactly 24 hourly values")

    wd = WeatherData(
        Tdb=_as_array_24xn(wd_raw["Tdb"], "weather_info.temp_dry", np, n_day),
        Twb=_as_array_24xn(wd_raw["Twb"], "weather_info.temp_wet", np, n_day),
        S=_as_array_24xn(wd_raw["S"], "weather_info.solar_irradiance", np, n_day),
        vw=_as_array_24xn(wd_raw["vw"], "weather_info.wind_speed", np, n_day),
        w=w,
        d=d,
        EF=_as_array_24xn(wd_raw["EF"], "weather_info.grid_carbon_factor", np, n_day),
    )
    td = TariffData(
        price_MWh=price * 1000,
        fee_MW=float(td_raw["cap_fee_kw_mon"]) * 1000,
        export_MWh=float(td_raw["export_price_kwh"]) * 1000,
    )
    return wd, td


def _weighted_hourly_average(matrix, weights, np):
    arr = np.array(matrix, dtype=float)
    w = np.array(weights, dtype=float)
    return (arr @ w / max(float(w.sum()), 1e-9)).tolist()


def _province_payload(province_key: str):
    if province_key not in WEATHER_DATA or province_key not in TARIFF_DATA:
        raise HTTPException(404, "Province not found")
    import numpy as np
    wd = WEATHER_DATA[province_key]
    td = TARIFF_DATA[province_key]
    w = wd["w"]
    solar_avg = _weighted_hourly_average(wd["S"], w, np)
    wind_avg = _weighted_hourly_average(wd["vw"], w, np)
    temp_dry_avg = _weighted_hourly_average(wd["Tdb"], w, np)
    temp_wet_avg = _weighted_hourly_average(wd["Twb"], w, np)
    from core.optimizer import cop_from_twb
    cop_avg = _weighted_hourly_average(cop_from_twb(np.array(wd["Twb"], dtype=float)), w, np)
    carbon_avg = _weighted_hourly_average(wd["EF"], w, np)
    return {
        "key": province_key,
        "name": PROVINCE_NAMES.get(province_key, province_key),
        "weather_summary": {
            "solar_hourly_avg": solar_avg,
            "wind_hourly_avg": wind_avg,
            "temp_dry_hourly_avg": temp_dry_avg,
            "temp_wet_hourly_avg": temp_wet_avg,
            "cop_hourly_avg": cop_avg,
            "carbon_factor_hourly_avg": carbon_avg,
            "typical_day_weight": list(w),
            "solar_score": min(100, round(max(solar_avg) / 10)),
            "wind_score": min(100, round((sum(wind_avg) / len(wind_avg)) * 8)),
        },
        "tariff_info": {
            "grid_price": td["price_kwh"],
            "capacity_fee": td["cap_fee_kw_mon"],
            "export_price": td["export_price_kwh"],
            "min_price": min(td["price_kwh"]),
            "max_price": max(td["price_kwh"]),
            "avg_price": sum(td["price_kwh"]) / len(td["price_kwh"]),
        },
    }


def _apply_device_param(cfg, scenario: dict):
    mapping = {
        "discount_rate": "i_rate", "life_pv": "n_pv", "life_wt": "n_wt",
        "life_battery": "n_ba", "life_cold_storage": "n_ct", "life_line": "n_line",
        "pv_cap_cost": "cap_cost_pv", "pv_om_cost": "om_pv",
        "wt_cap_cost": "cap_cost_wt", "wt_om_cost": "om_wt",
        "battery_cap_cost": "cap_cost_ba", "battery_om_rate": "om_rate_ba",
        "cold_storage_cap_cost": "cap_cost_ct", "cold_storage_om_rate": "om_rate_ct",
        "line_capex": "lineCapex", "pv_cap_max": "CpvMax",
        "wt_cap_max": "CwtMax", "battery_cap_max": "CbaMax",
        "cold_storage_cap_max": "CctMax", "battery_efficiency": "eta_ba",
        "battery_power_ratio": "p_ratio_ba", "battery_soc_min": "SOCmin_ba",
        "battery_soc_max": "SOCmax_ba", "battery_soc_initial": "SOC0_ba",
        "cold_storage_efficiency": "eta_ct", "cold_storage_power_ratio": "p_ratio_ct",
        "cold_storage_soc_min": "SOCmin_ct", "cold_storage_soc_max": "SOCmax_ct",
        "cold_storage_soc_initial": "SOC0_ct", "wind_cut_in": "vin",
        "wind_rated": "vr", "wind_cut_out": "vout", "pv_temp_coeff": "eps_pv",
    }
    for legacy, attr in {"cap_cost_pv":"cap_cost_pv", "cap_cost_wt":"cap_cost_wt", "cap_cost_ba":"cap_cost_ba", "cap_cost_ct":"cap_cost_ct"}.items():
        if scenario.get(legacy) is not None:
            setattr(cfg, attr, scenario[legacy])
    device_param = scenario.get("device_param") or {}
    for src, dst in mapping.items():
        if device_param.get(src) is not None:
            setattr(cfg, dst, device_param[src])


def _safe(v):
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    return v


def _result_to_scan_row(r, wd):
    bess_days = list(r.BESS_EFC_day or []) + [0] * 6
    row = {
        "z": r.z,
        "Cpv": r.Cpv, "Cwt": r.Cwt, "Cba": r.Cba, "Cct": r.Cct,
        "cpv": r.Cpv, "cwt": r.Cwt, "cba": r.Cba, "cct": r.Cct,
        "P_peak_IT_base": r.P_peak_IT_base,
        "P_peak_IT_shifted": r.P_peak_IT_shifted,
        "Qch_cap_max": r.Qch_cap_max,
        "GEP_actual": r.GEP_actual, "gep_actual": r.GEP_actual,
        "GEP_target": r.GEP_target, "gep_target": r.GEP_target,
        "GEP_max_target_feasible": getattr(r, "GEP_max_target_feasible", None),
        "feasible": r.feasible,
        "GreenHours_actual": r.GreenHours_actual, "green_hours": r.GreenHours_actual,
        "GreenHourShare_actual": r.GreenHourShare_actual, "green_hour_share": r.GreenHourShare_actual,
        "LCOE_IT": _safe(r.LCOE_IT), "lcoe_it": _safe(r.LCOE_IT),
        "LCOE_total": _safe(r.LCOE_total), "lcoe_total": _safe(r.LCOE_total),
        "LCOE_pv": _safe(r.LCOE_pv), "LCOE_wt": _safe(r.LCOE_wt),
        "IT_demand_annual": r.IT_demand_annual,
        "ChillerElec_annual": r.ChillerElec_annual,
        "TotalElec_annual": r.TotalElec_annual,
        "Carbon_total": r.Carbon_total_kgCO2e, "carbon_total": r.Carbon_total_kgCO2e,
        "PUE": _safe(r.PUE), "pue": _safe(r.PUE),
        "CUE": _safe(r.CUE), "cue": _safe(r.CUE),
        "pv_used_annual": r.pv_used_annual, "wt_used_annual": r.wt_used_annual,
        "pv_potential_annual": r.pv_pot_annual, "wt_potential_annual": r.wt_pot_annual,
        "RE_used_annual": r.RE_used_annual, "RE_potential_annual": r.RE_pot_annual,
        "Curt_PV_annual": r.CurtPV_annual, "Curt_WT_annual": r.CurtWT_annual,
        "Curt_total_annual": r.CurtTot_annual,
        "Curt_rate": r.CurtRate, "curt_rate": r.CurtRate,
        "grid_annual": r.grid_annual, "export_annual": r.export_annual,
        "export_ratio_to_RE_potential": r.export_ratio,
        "Cost_PV": r.Cost_PV, "cost_pv": r.Cost_PV,
        "Cost_WT": r.Cost_WT, "cost_wt": r.Cost_WT,
        "Cost_BA": r.Cost_BA, "cost_ba": r.Cost_BA,
        "Cost_CT": r.Cost_CT, "cost_ct": r.Cost_CT,
        "ExportRevenue": r.ExportRevenue, "export_revenue": r.ExportRevenue,
        "Cost_GridEnergy": r.Grid_energy_cost, "grid_energy_cost": r.Grid_energy_cost,
        "Cost_CapacityFee": r.CapacityFee, "capacity_fee": r.CapacityFee,
        "Cost_Line": r.Cost_Line, "cost_line": r.Cost_Line,
        "CAPEX_total": r.CAPEX_total, "capex_total": r.CAPEX_total,
        "OPEX_total": r.OPEX_total, "opex_total": r.OPEX_total,
        "BESS_EFC_annual": r.BESS_EFC_annual,
        "BESS_EFC_day1": bess_days[0], "BESS_EFC_day2": bess_days[1], "BESS_EFC_day3": bess_days[2],
        "BESS_EFC_day4": bess_days[3], "BESS_EFC_day5": bess_days[4], "BESS_EFC_day6": bess_days[5],
        "Share_PV": r.Share_PV, "share_pv": r.Share_PV,
        "Share_WT": r.Share_WT, "share_wt": r.Share_WT,
        "Share_BA": r.Share_BA, "share_ba": r.Share_BA,
        "Share_CT": r.Share_CT, "share_ct": r.Share_CT,
        "Share_Grid": r.Share_Grid, "share_grid": r.Share_Grid,
        "Share_Line": r.Share_Line,
        "alpha": r.alpha,
        "Dur_BESS_base": r.Dur_BESS_base, "Dur_BESS_shifted": r.Dur_BESS_shifted,
        "Dur_CT_base": r.Dur_CT_base, "Dur_CT_shifted": r.Dur_CT_shifted,
        "Peak_reduction_IT": r.Peak_reduction_IT,
        "Peak_reduction_IT_ratio": r.Peak_reduction_IT_ratio,
        "LoadStd_IT_base": r.LoadStd_IT_base,
        "LoadStd_IT_shifted": r.LoadStd_IT_shifted,
        "LoadProfileCode": r.LoadProfileCode,
        "MeanITLoad24h": r.MeanITLoad24h,
        "solve_time": r.solve_time,
    }
    if r.feasible and r.Pg_mat is not None:
        row["dispatch"] = _dispatch_payload(r, wd)
    else:
        row["dispatch"] = None
    return row


def _dispatch_payload(r, wd):
    raw = {
        "pg": r.Pg_mat, "ppv": r.Ppv_use_mat, "pwt": r.Pwt_use_mat,
        "ppv_avail": r.Ppv_avail_mat, "pwt_avail": r.Pwt_avail_mat,
        "pexp": r.Pexp_mat, "pba_c": r.Pba_c_mat, "pba_d": r.Pba_d_mat, "eba": r.Eba_mat,
        "ld_it": r.Ld_IT_mat, "pch_total": r.Pch_tot_mat,
        "pch_direct": r.Pch_dir_mat, "pch_charge": r.Pch_charge_mat,
        "qch_direct": r.Qch_dir_mat, "qct_charge": r.Qct_c_mat,
        "qct_discharge": r.Qct_d_mat, "e_ct": r.Ect_mat,
        "shift_out": r.Shift_out_mat, "shift_in": r.Shift_in_mat,
        "cop": r.COP_mat, "temp_dry": wd.Tdb, "temp_wet": wd.Twb,
        "carbon_factor": wd.EF,
    }
    payload = {k: (v.tolist() if v is not None else None) for k, v in raw.items()}
    detail = []
    if r.Pg_mat is not None:
        for j in range(r.Pg_mat.shape[1]):
            for t in range(24):
                pg = float(r.Pg_mat[t, j])
                detail.append({
                    "season": j + 1, "hour": t + 1,
                    "typical_day_weight": float(wd.w[j]),
                    "temp_dry": float(wd.Tdb[t, j]), "temp_wet": float(wd.Twb[t, j]),
                    "cop": float(r.COP_mat[t, j]) if r.COP_mat is not None else None,
                    "load_it_base": float(wd.d[t]),
                    "load_it_shifted": float(r.Ld_IT_mat[t, j]),
                    "shift_out": float(r.Shift_out_mat[t, j]) if r.Shift_out_mat is not None else 0,
                    "shift_in": float(r.Shift_in_mat[t, j]) if r.Shift_in_mat is not None else 0,
                    "cool_demand": float(r.Ld_IT_mat[t, j]),
                    "qch_direct": float(r.Qch_dir_mat[t, j]) if r.Qch_dir_mat is not None else 0,
                    "qct_charge": float(r.Qct_c_mat[t, j]) if r.Qct_c_mat is not None else 0,
                    "qct_discharge": float(r.Qct_d_mat[t, j]) if r.Qct_d_mat is not None else 0,
                    "e_ct": float(r.Ect_mat[t, j]) if r.Ect_mat is not None else 0,
                    "pch_direct": float(r.Pch_dir_mat[t, j]) if r.Pch_dir_mat is not None else 0,
                    "pch_charge": float(r.Pch_charge_mat[t, j]) if r.Pch_charge_mat is not None else 0,
                    "pch_total": float(r.Pch_tot_mat[t, j]) if r.Pch_tot_mat is not None else 0,
                    "ppv_use": float(r.Ppv_use_mat[t, j]), "pwt_use": float(r.Pwt_use_mat[t, j]),
                    "ppv_avail": float(r.Ppv_avail_mat[t, j]) if r.Ppv_avail_mat is not None else 0,
                    "pwt_avail": float(r.Pwt_avail_mat[t, j]) if r.Pwt_avail_mat is not None else 0,
                    "pg": pg, "carbon_factor": float(wd.EF[t, j]),
                    "grid_carbon_contribution": pg * 1000 * float(wd.EF[t, j]) * float(wd.w[j]),
                    "pexp": float(r.Pexp_mat[t, j]) if r.Pexp_mat is not None else 0,
                    "pba_c": float(r.Pba_c_mat[t, j]), "pba_d": float(r.Pba_d_mat[t, j]),
                    "e_ba": float(r.Eba_mat[t, j]),
                    "is_green_hour": 1 if pg <= 1e-6 else 0,
                    "green_hour_contribution": float(wd.w[j]) if pg <= 1e-6 else 0,
                })
    payload["detail"] = detail
    return payload


def _merge_simulation_load_info(project: dict, scenario: dict):
    """Merge project load data with simulation-time data center load characteristics."""
    load_info = dict(project.get("load_info") or {})
    dc_load = scenario.get("data_center_load") or {}

    if dc_load.get("it_load") is not None:
        load_info["it_load"] = dc_load["it_load"]
        load_info["load_source"] = "scenario_24h"
    elif dc_load.get("mean_it_load_mw") is not None:
        load_info["it_load"] = [float(dc_load["mean_it_load_mw"])] * 24
        load_info["load_source"] = "scenario_mean"
    elif "load_source" not in load_info:
        load_info["load_source"] = "project_or_province_default"

    for key in (
        "load_profile", "chiller_cap_multiplier", "it_load_cap_s3",
        "qch_cap_max_s3", "alpha", "flex_windows",
    ):
        if dc_load.get(key) is not None:
            load_info[key] = dc_load[key]

    return load_info


def _metric_series(scan_result):
    def series(key):
        return [r.get(key) for r in scan_result]
    return {
        "lcoe_it_series": series("LCOE_IT"),
        "lcoe_total_series": series("LCOE_total"),
        "gep_series": series("GEP_actual"),
        "green_hours_series": series("GreenHours_actual"),
        "green_hour_share_series": series("GreenHourShare_actual"),
        "curt_rate_series": series("Curt_rate"),
        "cpv_series": series("Cpv"), "cwt_series": series("Cwt"),
        "cba_series": series("Cba"), "cct_series": series("Cct"),
        "curtail_total_series": series("Curt_total_annual"),
        "chiller_elec_series": series("ChillerElec_annual"),
        "total_elec_series": series("TotalElec_annual"),
        "carbon_total_series": series("Carbon_total"),
        "pue_series": series("PUE"), "cue_series": series("CUE"),
        "ppeak_shifted_series": series("P_peak_IT_shifted"),
        "dur_bess_shifted_series": series("Dur_BESS_shifted"),
        "dur_ct_shifted_series": series("Dur_CT_shifted"),
        "capex_total_series": series("CAPEX_total"),
        "opex_total_series": series("OPEX_total"),
        "export_annual_series": series("export_annual"),
        "export_revenue_series": series("ExportRevenue"),
        "export_ratio_series": series("export_ratio_to_RE_potential"),
        "bess_efc_annual_series": series("BESS_EFC_annual"),
        "bess_efc_day_series": [[r.get(f"BESS_EFC_day{i}") for r in scan_result] for i in range(1, 7)],
    }


def run_simulation_sync(run_id: str, project_id: str, scenario: dict):
    """在后台线程中运行优化求解"""
    try:
        simulation_runs[run_id]["status"] = "running"
        simulation_runs[run_id]["started_at"] = datetime.now().isoformat()

        proj = projects[project_id]

        import numpy as np
        from core.optimizer import OptimizerConfig, solve_region, cop_from_twb

        load_info = _merge_simulation_load_info(proj, scenario)
        proj_for_run = {**proj, "load_info": load_info}
        wd, td = _build_weather_tariff(proj_for_run, np)
        gep_targets = scenario.get("gep_targets") or make_gep_targets(
            scenario["gep_start"], scenario["gep_end"], scenario["gep_step"]
        )

        solver_param = scenario.get("solver_param") or {}
        cfg = OptimizerConfig(
            scenario=scenario["scenario_type"],
            objective=scenario["objective_mode"],
            policy=scenario["policy_scenario"],
            alpha=scenario.get("alpha", load_info.get("alpha", 0.0)),
            flex_windows=scenario.get("flex_windows") or load_info.get("flex_windows") or [2, 5, 8, 12],
            gep_targets=gep_targets,
            ramp_weight=scenario.get("ramp_weight", 0.25),
            curt_rate_limit=scenario.get("curt_rate_limit", 0.40),
            export_ratio_limit=scenario.get("export_ratio_limit", 0.20),
            pg_zero_tol=scenario.get("pg_zero_tol", 1e-6),
            grid_zero_tol_annual=scenario.get("grid_zero_tol_annual", 1e-6),
            gep_tol=scenario.get("gep_tol", 5e-9),
            carbon_lexicographic=scenario.get("carbon_lexicographic", True),
            cost_tie_rel_tol=scenario.get("cost_tie_rel_tol", 1e-4),
            cost_tie_abs_tol=scenario.get("cost_tie_abs_tol", 1e3),
            carbon_lex_rel_tol=scenario.get("carbon_lex_rel_tol", 1e-6),
            carbon_lex_abs_tol_kg=scenario.get("carbon_lex_abs_tol_kg", 1e3),
            load_profile=scenario.get("load_profile") or load_info.get("load_profile", "raw"),
            chiller_cap_multiplier=load_info.get("chiller_cap_multiplier", 1.5),
            IT_load_cap_S3=scenario.get("it_load_cap_s3") or load_info.get("it_load_cap_s3", 500.0),
            Qch_cap_max_S3=scenario.get("qch_cap_max_s3") or load_info.get("qch_cap_max_s3", 750.0),
            solver=solver_param.get("solver", "auto"),
            time_limit=solver_param.get("time_limit", 120.0),
            mip_gap=solver_param.get("mip_gap", 5e-3),
            verbose=solver_param.get("verbose", 0),
        )
        _apply_device_param(cfg, scenario)

        def progress_cb(z, n, s_target):
            simulation_runs[run_id]["progress"] = round(z / max(n, 1) * 100)
            simulation_runs[run_id]["current_gep"] = s_target

        results, best_points = solve_region(
            wd, td, cfg,
            write_dispatch=scenario.get("write_dispatch", True),
            progress_callback=progress_cb,
        )

        scan_result = [_result_to_scan_row(r, wd) for r in results]
        metric_series = _metric_series(scan_result)
        run_meta = {
            "scenario": cfg.scenario,
            "policy_scenario": cfg.policy,
            "policy_description": {"A": "无新增约束/不上网", "B": "弃电率上限", "C": "弃电率上限+上网比例上限"}.get(cfg.policy, cfg.policy),
            "objective_mode": cfg.objective,
            "objective_description": "年总成本最小" if cfg.objective == "cost" else "年总碳排放最小",
            "optimization_method": "greenfollow_ramp" if cfg.objective == "cost" else "carbon_ramp",
            "ramp_weight": cfg.ramp_weight,
            "cost_tie_rel_tol": cfg.cost_tie_rel_tol,
            "cost_tie_abs_tol": cfg.cost_tie_abs_tol,
            "carbon_lexicographic": cfg.carbon_lexicographic,
            "carbon_lex_rel_tol": cfg.carbon_lex_rel_tol,
            "carbon_lex_abs_tol_kg": cfg.carbon_lex_abs_tol_kg,
            "carbon_accounting": "购电 Pg 乘以对应时段电网碳因子，不对上网电量抵扣。",
            "pue_definition": "PUE = TotalElec_annual / IT_demand_annual",
            "cue_definition": "CUE = Carbon_total_kg / (IT_demand_annual * 1000)",
            "curt_rate_limit": cfg.curt_rate_limit if cfg.policy in ("B", "C") else None,
            "use_export": cfg.policy == "C",
            "export_ratio_limit": cfg.export_ratio_limit if cfg.policy == "C" else None,
            "alpha": cfg.alpha,
            "load_profile": cfg.load_profile,
            "data_center_load_source": load_info.get("load_source"),
            "mean_it_load_mw": float(np.mean(wd.d)),
            "peak_it_load_mw": float(np.max(wd.d)),
            "chiller_cap_multiplier": cfg.chiller_cap_multiplier,
            "weather_inputs": ["temp_dry", "temp_wet", "solar_irradiance", "wind_speed", "typical_day_weight", "grid_carbon_factor"],
            "mean_temp_dry_degC": float(np.mean(wd.Tdb)),
            "mean_temp_wet_degC": float(np.mean(wd.Twb)),
            "mean_cop": float(np.mean(cop_from_twb(wd.Twb))),
            "use_storage": cfg.scenario in ("S1", "S2", "S3"),
            "use_cold_storage": cfg.scenario in ("S2", "S3"),
            "use_flex": cfg.scenario == "S3",
            "pg_zero_tol": cfg.pg_zero_tol,
            "grid_zero_tol_annual": cfg.grid_zero_tol_annual,
            "shares_step": scenario.get("gep_step"),
            "tol": cfg.gep_tol,
        }

        simulation_runs[run_id].update({
            "status": "completed",
            "finished_at": datetime.now().isoformat(),
            "progress": 100,
            "run_meta": run_meta,
            "scan_result": scan_result,
            "best_points": best_points,
            "metric_series": metric_series,
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


@app.get("/api/provinces/{province_key}/data")
def get_province_data(province_key: str):
    """获取省份电价与资源诊断摘要，供前端预览使用。"""
    return _province_payload(province_key)


@app.post("/api/projects")
def create_project(body: ProjectCreate):
    project_id = str(uuid.uuid4())[:8]
    proj = {
        "id": project_id,
        "name": body.name,
        "region_name": body.region_name,
        "data_year": body.data_year,
        "typical_day_count": body.typical_day_count,
        "time_step_hours": body.time_step_hours,
        "province_key": body.province_key or "Prov1",
        "description": body.description,
        "weather_info": body.weather_info.model_dump() if body.weather_info else None,
        "tariff_info": body.tariff_info.model_dump() if body.tariff_info else None,
        "load_info": body.load_info.model_dump() if body.load_info else None,
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


@app.put("/api/projects/{project_id}/inputs")
def update_project_inputs(project_id: str, body: ProjectInputUpdate):
    if project_id not in projects:
        raise HTTPException(404, "Project not found")
    proj = projects[project_id]
    if body.weather_info is not None:
        proj["weather_info"] = body.weather_info
    if body.tariff_info is not None:
        proj["tariff_info"] = body.tariff_info
    if body.load_info is not None:
        proj["load_info"] = body.load_info
    proj["updated_at"] = datetime.now().isoformat()
    return proj


@app.post("/api/scenarios/run")
def create_and_run(body: ScenarioConfig, background_tasks: BackgroundTasks):
    if body.project_id not in projects:
        raise HTTPException(404, "Project not found")

    scenario_id = str(uuid.uuid4())[:8]
    run_id = str(uuid.uuid4())[:8]

    scenario = body.model_dump()
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
        "run_meta": r.get("run_meta"),
        "scan_result": r["scan_result"],
        "best_points": r["best_points"],
        "metric_series": r.get("metric_series"),
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
    if gep_index < 0 or gep_index >= len(scan):
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
    results = []
    for pct in body.range_pct:
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


@app.get("/api/interface-schema")
def get_interface_schema():
    """返回接口文档对应的输入/输出对象说明，便于前端动态渲染或第三方系统对接。"""
    return {
        "input_objects": [
            "region_info", "weather_info", "tariff_info", "load_info",
            "scenario_info", "device_param", "solver_param"
        ],
        "output_objects": ["run_meta", "scan_result", "best_points", "metric_series", "dispatch_detail"],
        "models": {
            "project_create": ProjectCreate.model_json_schema(),
            "project_input_update": ProjectInputUpdate.model_json_schema(),
            "scenario_config": ScenarioConfig.model_json_schema(),
            "weather_info": WeatherInfo.model_json_schema(),
            "tariff_info": TariffInfo.model_json_schema(),
            "load_info": LoadInfo.model_json_schema(),
            "data_center_load": DataCenterLoadInfo.model_json_schema(),
            "device_param": DeviceParam.model_json_schema(),
            "solver_param": SolverParam.model_json_schema(),
        },
    }


@app.get("/api/health")
def health():
    return {"status": "ok", "time": datetime.now().isoformat()}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
