"""
green_direct_optimizer.py
=========================
Python translation of green_direct_carbon_objective_greenfollow_ramp_v1.m

Solves the GEP-scan MILP for a single region (single province):
  - S0: No storage, no flexibility
  - S1: Battery storage only
  - S2: Battery + cold storage (with COP(Twb))
  - S3: Battery + cold storage + IT load time-shift (alpha)

Solver: PuLP (default CBC) or Gurobi (if available)
"""

import math
import time
import logging
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict, Any

import numpy as np

try:
    import pulp
    HAS_PULP = True
except ImportError:
    HAS_PULP = False

try:
    from gurobipy import Model, GRB, quicksum
    HAS_GUROBI = True
except ImportError:
    HAS_GUROBI = False

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════
#  DATA CLASSES
# ══════════════════════════════════════════════════════════

@dataclass
class WeatherData:
    """24×N_day arrays from weather file."""
    Tdb: np.ndarray          # dry-bulb temp [24, n_day]
    Twb: np.ndarray          # wet-bulb temp [24, n_day]
    S: np.ndarray            # solar irradiance W/m² [24, n_day]
    vw: np.ndarray           # wind speed m/s [24, n_day]
    w: np.ndarray            # typical day weights [n_day]
    d: np.ndarray            # IT load MW [24] (base)
    EF: np.ndarray           # grid carbon factor kgCO2/kWh [24, n_day]


@dataclass
class TariffData:
    price_MWh: np.ndarray    # [24] ¥/MWh
    fee_MW: float            # ¥/MW/month
    export_MWh: float        # ¥/MWh


@dataclass
class OptimizerConfig:
    scenario: str = "S1"          # S0/S1/S2/S3
    objective: str = "cost"       # cost/carbon
    policy: str = "A"             # A/B/C
    alpha: float = 0.0            # S3 shift fraction
    flex_windows: List[int] = field(default_factory=lambda: [2, 5, 8, 12])
    gep_targets: List[float] = field(default_factory=lambda: [i/20 for i in range(21)])
    load_profile: str = "raw"     # raw/flat/day_peak/night_bias/dual_peak
    # Policy
    curt_rate_limit: float = 0.40
    export_ratio_limit: float = 0.20
    # Chiller and S3 caps
    chiller_cap_multiplier: float = 1.5
    IT_load_cap_S3: float = 500.0
    Qch_cap_max_S3: float = 750.0
    # Device params
    i_rate: float = 0.06
    n_pv: int = 20; n_wt: int = 20; n_ba: int = 7; n_ct: int = 20; n_line: int = 15
    cap_cost_pv: float = 3_080_000   # ¥/MW
    cap_cost_wt: float = 4_500_000
    cap_cost_ba: float = 1_400_000   # ¥/MWh
    cap_cost_ct: float = 222_000     # ¥/MWh_th
    om_pv: float = 70_000            # ¥/MW/yr
    om_wt: float = 100_000
    om_rate_ba: float = 0.005
    om_rate_ct: float = 0.007
    lineCapex: float = 2e8
    CpvMax: float = 1e6
    CwtMax: float = 1e6
    CbaMax: float = 1e6
    CctMax: float = 1e6
    eta_ba: float = 0.95
    p_ratio_ba: float = 0.2
    SOCmin_ba: float = 0.1; SOCmax_ba: float = 0.9; SOC0_ba: float = 0.5
    eta_ct: float = 0.95
    p_ratio_ct: float = 0.2
    SOCmin_ct: float = 0.1; SOCmax_ct: float = 0.9; SOC0_ct: float = 0.5
    eps_pv: float = -0.0006         # PV temperature coefficient
    vin: float = 3; vr: float = 12; vout: float = 25
    pg_zero_tol: float = 1e-6       # MW
    grid_zero_tol_annual: float = 1e-6  # MWh
    gep_tol: float = 5e-9
    ramp_weight: float = 0.25
    cost_tie_rel_tol: float = 1e-4
    cost_tie_abs_tol: float = 1e3
    carbon_lexicographic: bool = True
    carbon_lex_rel_tol: float = 1e-6
    carbon_lex_abs_tol_kg: float = 1e3
    solver: str = "auto"           # auto/cbc/gurobi
    time_limit: float = 120.0      # seconds per GEP target
    mip_gap: float = 5e-3
    verbose: int = 0


@dataclass
class GEPResult:
    z: int
    GEP_target: float
    GEP_actual: float
    feasible: bool
    Cpv: float = 0; Cwt: float = 0; Cba: float = 0; Cct: float = 0
    P_peak_IT_base: float = 0; P_peak_IT_shifted: float = 0
    Qch_cap_max: float = 0
    GreenHours_actual: float = 0; GreenHourShare_actual: float = 0
    LCOE_IT: float = float("nan"); LCOE_total: float = float("nan")
    LCOE_pv: float = float("nan"); LCOE_wt: float = float("nan")
    IT_demand_annual: float = 0; ChillerElec_annual: float = 0
    TotalElec_annual: float = 0
    Carbon_total_kgCO2e: float = 0
    PUE: float = float("nan"); CUE: float = float("nan")
    pv_used_annual: float = 0; wt_used_annual: float = 0
    pv_pot_annual: float = 0; wt_pot_annual: float = 0
    RE_used_annual: float = 0; RE_pot_annual: float = 0
    CurtPV_annual: float = 0; CurtWT_annual: float = 0
    CurtTot_annual: float = 0; CurtRate: float = 0
    grid_annual: float = 0; export_annual: float = 0
    export_ratio: float = 0
    ObjCost: float = 0; CAPEX_total: float = 0; OPEX_total: float = 0
    Cost_PV: float = 0; Cost_WT: float = 0; Cost_BA: float = 0
    Cost_CT: float = 0; Cost_Line: float = 0
    Grid_energy_cost: float = 0; ExportRevenue: float = 0
    CapacityFee: float = 0
    Share_PV: float = 0; Share_WT: float = 0; Share_BA: float = 0
    Share_CT: float = 0; Share_Grid: float = 0; Share_Line: float = 0
    BESS_EFC_annual: float = 0; BESS_EFC_day: List[float] = field(default_factory=list)
    alpha: float = 0
    Dur_BESS_base: float = 0; Dur_BESS_shifted: float = 0
    Dur_CT_base: float = 0; Dur_CT_shifted: float = 0
    Peak_reduction_IT: float = 0; Peak_reduction_IT_ratio: float = 0
    LoadStd_IT_base: float = 0; LoadStd_IT_shifted: float = 0
    LoadProfileCode: int = 0; MeanITLoad24h: float = 0
    # dispatch arrays (optional)
    Pg_mat: Optional[np.ndarray] = None
    Ppv_use_mat: Optional[np.ndarray] = None
    Pwt_use_mat: Optional[np.ndarray] = None
    Pba_c_mat: Optional[np.ndarray] = None
    Pba_d_mat: Optional[np.ndarray] = None
    Eba_mat: Optional[np.ndarray] = None
    Ld_IT_mat: Optional[np.ndarray] = None
    Pch_tot_mat: Optional[np.ndarray] = None
    Pch_dir_mat: Optional[np.ndarray] = None
    Pch_charge_mat: Optional[np.ndarray] = None
    Qch_dir_mat: Optional[np.ndarray] = None
    Qct_c_mat: Optional[np.ndarray] = None
    Qct_d_mat: Optional[np.ndarray] = None
    Ect_mat: Optional[np.ndarray] = None
    Pexp_mat: Optional[np.ndarray] = None
    Ppv_avail_mat: Optional[np.ndarray] = None
    Pwt_avail_mat: Optional[np.ndarray] = None
    Shift_out_mat: Optional[np.ndarray] = None
    Shift_in_mat: Optional[np.ndarray] = None
    COP_mat: Optional[np.ndarray] = None
    solve_time: float = 0


# ══════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS  (direct translation from MATLAB)
# ══════════════════════════════════════════════════════════

def cop_from_twb(Twb: np.ndarray) -> np.ndarray:
    """COP as function of wet-bulb temperature (°C). Piecewise empirical."""
    COP = np.zeros_like(Twb, dtype=float)
    m1 = Twb <= -5
    COP[m1] = -0.001457 * Twb[m1]**2 - 0.1068 * Twb[m1] + 9.0156
    m2 = (Twb > -5) & (Twb <= 7)
    COP[m2] = -0.0079437 * Twb[m2]**2 - 0.05831 * Twb[m2] + 10.901
    m3 = (Twb > 7) & (Twb <= 15)
    COP[m3] = -0.0074756 * Twb[m3]**2 + 0.1311 * Twb[m3] + 5.1232
    m4 = Twb > 15
    COP[m4] = -0.0778 * Twb[m4] + 6.4832
    COP = np.maximum(COP, 0.5)
    return COP


def compute_wind_cf(vw: np.ndarray, vin: float, vr: float, vout: float) -> np.ndarray:
    """Wind capacity factor from wind speed."""
    cf = np.zeros_like(vw, dtype=float)
    m_mid = (vw >= vin) & (vw < vr)
    cf[m_mid] = (vw[m_mid]**3 - vin**3) / (vr**3 - vin**3)
    cf[(vw >= vr) & (vw < vout)] = 1.0
    return cf


def compute_pv_kp(Tdb: np.ndarray, S: np.ndarray, vw: np.ndarray, eps_pv: float) -> np.ndarray:
    """PV available output coefficient (per MW installed)."""
    Tm = Tdb + 0.0138 * S * (1 - 0.042 * vw) * (1 + 0.031 * Tdb)
    kp = S * (1 + eps_pv * (Tm - 25)) / 1000
    kp = np.maximum(kp, 0.0)
    return kp


def compute_green_hours(Pg: np.ndarray, w: np.ndarray, pg_zero_tol: float) -> Tuple[float, float]:
    """Annual green hours and share, weighted by typical-day weights."""
    flag = (Pg <= pg_zero_tol).astype(float)
    contrib = flag * w[np.newaxis, :]     # [24, n_day]
    annual = float(np.sum(contrib))
    share = annual / 8760.0
    return max(annual, 0), min(max(share, 0), 1)


def compute_bess_efc(Pba_c: np.ndarray, Pba_d: np.ndarray, Cba: float, w: np.ndarray):
    """BESS equivalent full cycles: daily and annual."""
    if Cba < 1e-8:
        return 0.0, np.zeros(len(w))
    charge_day = np.maximum(np.sum(Pba_c, axis=0), 0)
    discharge_day = np.maximum(np.sum(Pba_d, axis=0), 0)
    efc_day = 0.5 * (charge_day + discharge_day) / Cba
    efc_day[np.abs(efc_day) < 1e-10] = 0
    efc_annual = float(efc_day @ w)
    return efc_annual, efc_day.tolist()


def crf(rate: float, n: int) -> float:
    """Capital Recovery Factor."""
    return rate * (1 + rate)**n / ((1 + rate)**n - 1)


def get_it_profile(profile: str, mean_mw: float) -> np.ndarray:
    """IT load profiles, normalized to given mean."""
    profiles = {
        "flat":        [0.96,0.95,0.95,0.94,0.95,0.97,0.99,1.00,1.01,1.02,1.02,1.03,
                        1.03,1.02,1.02,1.01,1.00,1.00,0.99,0.99,0.98,0.98,0.97,0.96],
        "day_peak":    [0.72,0.70,0.68,0.67,0.69,0.74,0.84,0.98,1.12,1.24,1.32,1.36,
                        1.38,1.36,1.32,1.26,1.18,1.08,0.98,0.90,0.84,0.80,0.76,0.74],
        "night_bias":  [1.18,1.16,1.14,1.12,1.10,1.06,0.98,0.92,0.88,0.84,0.80,0.78,
                        0.76,0.78,0.82,0.88,0.94,1.00,1.06,1.12,1.18,1.22,1.22,1.20],
        "dual_peak":   [0.82,0.79,0.76,0.74,0.78,0.90,1.08,1.22,1.30,1.24,1.12,1.02,
                        0.96,0.98,1.04,1.16,1.30,1.36,1.32,1.20,1.06,0.96,0.88,0.84],
    }
    p = np.array(profiles[profile], dtype=float)
    p = p / p.mean()
    return mean_mw * p


# ══════════════════════════════════════════════════════════
#  MILP SOLVER (PuLP-based)
# ══════════════════════════════════════════════════════════

def _solve_one_gep_pulp(
    z: int,
    s_target: float,
    wd: WeatherData,
    td: TariffData,
    cfg: OptimizerConfig,
    kp: np.ndarray,      # [24, n_day] PV coeff
    cf: np.ndarray,      # [24, n_day] wind coeff
    invCOP: np.ndarray,  # [24, n_day]
    Qch_cap_max: float,
    contracted_demand: float,
    capacityfee_fixed: float,
    Pd_24x6: np.ndarray,  # [24, n_day] base IT load
    # Precomputed CRFs
    CRF_pv: float, CRF_wt: float, CRF_ba: float, CRF_ct: float, CRF_line: float,
    write_dispatch: bool = False,
) -> GEPResult:
    """Solve a single GEP target using PuLP LP relaxation (fast approximate)."""

    n_day = len(wd.w)
    w = wd.w
    T = 24
    use_storage = cfg.scenario in ("S1","S2","S3")
    use_cold    = cfg.scenario in ("S2","S3")
    use_flex    = cfg.scenario == "S3"

    prob = pulp.LpProblem(f"GreenDirect_z{z}", pulp.LpMinimize)

    # ── Capacity variables ──
    Cpv = pulp.LpVariable("Cpv", 0, cfg.CpvMax)
    Cwt = pulp.LpVariable("Cwt", 0, cfg.CwtMax)
    Cba = pulp.LpVariable("Cba", 0, cfg.CbaMax if use_storage else 0)
    Cct = pulp.LpVariable("Cct", 0, cfg.CctMax if use_cold else 0)

    if not use_storage:
        prob += Cba == 0
    if not use_cold:
        prob += Cct == 0

    # ── Dispatch variables [T × n_day] ──
    def mkvar2d(name, lb=0, ub=None):
        return [[pulp.LpVariable(f"{name}_{t}_{j}", lb, ub) for j in range(n_day)] for t in range(T)]

    Pg      = mkvar2d("Pg",  0, 1e5)
    Ppv_use = mkvar2d("Ppv", 0)
    Pwt_use = mkvar2d("Pwt", 0)
    Pexp    = mkvar2d("Pexp",0)
    Pba_c   = mkvar2d("Pba_c", 0)
    Pba_d   = mkvar2d("Pba_d", 0)
    Eba     = mkvar2d("Eba", 0)
    Qch_dir = mkvar2d("Qch_dir", 0)
    Qct_c   = mkvar2d("Qct_c", 0)
    Qct_d   = mkvar2d("Qct_d", 0)
    Ect     = mkvar2d("Ect", 0)

    Shift_total = None
    Received = None

    # ── IT load after shift ──
    if use_flex:
        nb = len(cfg.flex_windows)
        share_per_class = cfg.alpha / nb
        # Xcell[bi][tau][t][j] - load segments
        # Simplified: direct allocation variables for received load
        Received = [[pulp.LpVariable(f"Recv_{t}_{j}", 0) for j in range(n_day)] for t in range(T)]
        Shift_total = [[pulp.LpVariable(f"Shift_{t}_{j}", 0, cfg.alpha * Pd_24x6[t,j])
                        for j in range(n_day)] for t in range(T)]
        for j in range(n_day):
            total_shift_j = pulp.lpSum(Shift_total[t][j] for t in range(T))
            total_recv_j  = pulp.lpSum(Received[t][j]    for t in range(T))
            prob += total_shift_j == cfg.alpha * sum(Pd_24x6[t,j] for t in range(T))
            prob += total_recv_j  == total_shift_j
        Ld_IT = [[ (1-cfg.alpha)*Pd_24x6[t,j] + Received[t][j] for j in range(n_day)] for t in range(T)]
        # S3 IT load cap
        for t in range(T):
            for j in range(n_day):
                prob += Ld_IT[t][j] <= cfg.IT_load_cap_S3
    else:
        Ld_IT = [[Pd_24x6[t,j] for j in range(n_day)] for t in range(T)]

    # Derived: cooling electricity [t][j]
    Pch_dir = [[Qch_dir[t][j] * invCOP[t,j] for j in range(n_day)] for t in range(T)]
    Pch_ct  = [[Qct_c[t][j]   * invCOP[t,j] for j in range(n_day)] for t in range(T)]
    Pch_tot = [[Pch_dir[t][j] + Pch_ct[t][j] for j in range(n_day)] for t in range(T)]

    # ── Constraints ──
    p_ba_max_coeff = cfg.p_ratio_ba
    p_ct_max_coeff = cfg.p_ratio_ct

    for t in range(T):
        for j in range(n_day):
            ppv_av = kp[t,j]  # per MW
            pwt_av = cf[t,j]  # per MW

            # Wind/PV use bounded by available
            prob += Ppv_use[t][j] <= ppv_av * Cpv
            prob += Pwt_use[t][j] >= 0
            prob += Pwt_use[t][j] <= pwt_av * Cwt

            # Export bounded by curtailed RE
            prob += Pexp[t][j] <= (ppv_av * Cpv - Ppv_use[t][j]) + (pwt_av * Cwt - Pwt_use[t][j])
            prob += Pexp[t][j] >= 0

            # Battery bounds (LP relaxation: no binary, just rate limits)
            prob += Pba_c[t][j] <= p_ba_max_coeff * Cba
            prob += Pba_d[t][j] <= p_ba_max_coeff * Cba
            prob += Eba[t][j]   >= cfg.SOCmin_ba * Cba
            prob += Eba[t][j]   <= cfg.SOCmax_ba * Cba

            # Cold storage bounds
            prob += Qct_c[t][j] <= p_ct_max_coeff * Cct
            prob += Qct_d[t][j] <= p_ct_max_coeff * Cct
            prob += Ect[t][j]   >= cfg.SOCmin_ct * Cct
            prob += Ect[t][j]   <= cfg.SOCmax_ct * Cct

            # Cold balance: supply = IT load
            prob += Qch_dir[t][j] + Qct_d[t][j] == Ld_IT[t][j]
            prob += Qch_dir[t][j] + Qct_c[t][j] <= Qch_cap_max
            prob += Qch_dir[t][j] >= 0

            # Green-only charging: battery + cold charge electricity <= RE used
            prob += Pba_c[t][j] + Pch_ct[t][j] <= Ppv_use[t][j] + Pwt_use[t][j]

            # Power balance
            prob += (Ld_IT[t][j] + Pch_tot[t][j] + Pexp[t][j]
                     == Pg[t][j] + Ppv_use[t][j] + Pwt_use[t][j] + Pba_d[t][j] - Pba_c[t][j])

    # Battery SOC dynamics
    for j in range(n_day):
        prob += Eba[0][j] == cfg.SOC0_ba * Cba - Pba_d[0][j]/cfg.eta_ba + cfg.eta_ba*Pba_c[0][j]
        for t in range(1, T):
            prob += Eba[t][j] == Eba[t-1][j] - Pba_d[t][j]/cfg.eta_ba + cfg.eta_ba*Pba_c[t][j]
        prob += Eba[T-1][j] == cfg.SOC0_ba * Cba

    # Cold storage SOC dynamics
    for j in range(n_day):
        prob += Ect[0][j] == cfg.SOC0_ct*Cct - Qct_d[0][j]/cfg.eta_ct + cfg.eta_ct*Qct_c[0][j]
        for t in range(1, T):
            prob += Ect[t][j] == Ect[t-1][j] - Qct_d[t][j]/cfg.eta_ct + cfg.eta_ct*Qct_c[t][j]
        prob += Ect[T-1][j] == cfg.SOC0_ct * Cct

    # Annual aggregates (linear expressions)
    IT_annual  = pulp.lpSum(Ld_IT[t][j]*w[j]    for t in range(T) for j in range(n_day))
    chiller_an = pulp.lpSum(Pch_tot[t][j]*w[j]  for t in range(T) for j in range(n_day))
    total_an   = IT_annual + chiller_an
    grid_an    = pulp.lpSum(Pg[t][j]*w[j]        for t in range(T) for j in range(n_day))
    export_an  = pulp.lpSum(Pexp[t][j]*w[j]      for t in range(T) for j in range(n_day))
    pv_pot_an  = pulp.lpSum(kp[t,j]*w[j]         for t in range(T) for j in range(n_day)) * Cpv
    wt_pot_an  = pulp.lpSum(cf[t,j]*w[j]         for t in range(T) for j in range(n_day)) * Cwt
    RE_pot_an  = pv_pot_an + wt_pot_an
    curt_an    = RE_pot_an - pulp.lpSum((Ppv_use[t][j]+Pwt_use[t][j])*w[j]
                                        for t in range(T) for j in range(n_day))

    # Carbon
    carbon_total = 1000 * pulp.lpSum(Pg[t][j] * wd.EF[t,j] * w[j]
                                     for t in range(T) for j in range(n_day))

    # Policy constraints
    if cfg.policy == "A":
        # No export (default for policy A)
        for t in range(T):
            for j in range(n_day):
                prob += Pexp[t][j] == 0
    elif cfg.policy in ("B","C"):
        prob += curt_an <= cfg.curt_rate_limit * RE_pot_an
        if cfg.policy == "C":
            prob += export_an <= cfg.export_ratio_limit * RE_pot_an
        else:
            for t in range(T):
                for j in range(n_day):
                    prob += Pexp[t][j] == 0

    # GEP constraint
    tol = cfg.gep_tol
    if abs(s_target) < 1e-12:
        prob += Cpv == 0; prob += Cwt == 0; prob += Cba == 0; prob += Cct == 0
    elif abs(s_target - 1.0) < 1e-12:
        prob += grid_an <= cfg.grid_zero_tol_annual
    else:
        lb = max(0, s_target - tol)
        ub = min(1, s_target + tol)
        prob += grid_an >= (1 - ub) * total_an
        prob += grid_an <= (1 - lb) * total_an

    # ── Cost components ──
    Cost_PV   = (CRF_pv * cfg.cap_cost_pv + cfg.om_pv) * Cpv
    Cost_WT   = (CRF_wt * cfg.cap_cost_wt + cfg.om_wt) * Cwt
    Cost_BA   = (CRF_ba * cfg.cap_cost_ba + cfg.om_rate_ba * cfg.cap_cost_ba) * Cba
    Cost_CT   = (CRF_ct * cfg.cap_cost_ct + cfg.om_rate_ct * cfg.cap_cost_ct) * Cct
    Cost_Line = CRF_line * cfg.lineCapex   # fixed (no binary in LP)

    grid_energy_cost = pulp.lpSum(td.price_MWh[t] * Pg[t][j] * w[j]
                                  for t in range(T) for j in range(n_day))
    export_revenue = td.export_MWh * export_an

    ObjCost = Cost_PV + Cost_WT + Cost_BA + Cost_CT + Cost_Line + grid_energy_cost + capacityfee_fixed - export_revenue

    if cfg.objective == "cost":
        prob += ObjCost
    else:
        prob += carbon_total

    # ── Solve ──
    t0 = time.time()
    solver_name = cfg.solver.lower()
    if solver_name == "gurobi" and HAS_GUROBI:
        solver = pulp.GUROBI_CMD(msg=cfg.verbose, timeLimit=cfg.time_limit, gapRel=cfg.mip_gap)
    elif solver_name == "glpk":
        solver = pulp.GLPK_CMD(msg=cfg.verbose)
    else:
        solver = pulp.PULP_CBC_CMD(msg=cfg.verbose, timeLimit=cfg.time_limit, gapRel=cfg.mip_gap)

    prob.solve(solver)
    solve_time = time.time() - t0

    if prob.status != 1:  # not optimal
        return GEPResult(z=z, GEP_target=s_target, GEP_actual=float("nan"),
                         feasible=False, solve_time=solve_time)

    # ── Extract values ──
    def val(v):
        return pulp.value(v) or 0.0

    Cpv_v = max(val(Cpv), 0); Cwt_v = max(val(Cwt), 0)
    Cba_v = max(val(Cba), 0); Cct_v = max(val(Cct), 0)

    Pg_mat      = np.array([[val(Pg[t][j])      for j in range(n_day)] for t in range(T)])
    Ppv_mat     = np.array([[val(Ppv_use[t][j]) for j in range(n_day)] for t in range(T)])
    Pwt_mat     = np.array([[val(Pwt_use[t][j]) for j in range(n_day)] for t in range(T)])
    Pba_c_mat   = np.array([[val(Pba_c[t][j])   for j in range(n_day)] for t in range(T)])
    Pba_d_mat   = np.array([[val(Pba_d[t][j])   for j in range(n_day)] for t in range(T)])
    Eba_mat     = np.array([[val(Eba[t][j])      for j in range(n_day)] for t in range(T)])
    Qch_dir_mat = np.array([[val(Qch_dir[t][j]) for j in range(n_day)] for t in range(T)])
    Qct_c_mat   = np.array([[val(Qct_c[t][j])   for j in range(n_day)] for t in range(T)])
    Qct_d_mat   = np.array([[val(Qct_d[t][j])   for j in range(n_day)] for t in range(T)])
    Ect_mat     = np.array([[val(Ect[t][j])     for j in range(n_day)] for t in range(T)])
    Pexp_mat    = np.array([[val(Pexp[t][j])    for j in range(n_day)] for t in range(T)])
    if use_flex:
        Shift_out_mat = np.array([[val(Shift_total[t][j]) for j in range(n_day)] for t in range(T)])
        Shift_in_mat = np.array([[val(Received[t][j]) for j in range(n_day)] for t in range(T)])
        Ld_mat = np.array([[(1-cfg.alpha)*Pd_24x6[t,j]+val(Received[t][j]) for j in range(n_day)] for t in range(T)])
    else:
        Shift_out_mat = np.zeros((T, n_day))
        Shift_in_mat = np.zeros((T, n_day))
        Ld_mat = Pd_24x6.copy()

    Ppv_avail_mat = kp * Cpv_v
    Pwt_avail_mat = cf * Cwt_v
    COP_mat = 1.0 / np.maximum(invCOP, 1e-9)
    Pch_dir_mat = Qch_dir_mat * invCOP
    Pch_ct_mat  = Qct_c_mat  * invCOP
    Pch_tot_mat = Pch_dir_mat + Pch_ct_mat

    # Annual sums
    IT_an_v      = float(np.sum(np.sum(Ld_mat, axis=0) * w))
    chiller_an_v = float(np.sum(np.sum(Pch_tot_mat, axis=0) * w))
    total_an_v   = IT_an_v + chiller_an_v
    grid_an_v    = float(np.sum(np.sum(Pg_mat, axis=0) * w))
    export_an_v  = float(np.sum(np.sum(Pexp_mat, axis=0) * w))
    pv_pot_an_v  = float(np.sum(np.sum(kp * Cpv_v, axis=0) * w))
    wt_pot_an_v  = float(np.sum(np.sum(cf * Cwt_v, axis=0) * w))
    pv_used_an_v = float(np.sum(np.sum(Ppv_mat, axis=0) * w))
    wt_used_an_v = float(np.sum(np.sum(Pwt_mat, axis=0) * w))
    RE_pot_v  = pv_pot_an_v + wt_pot_an_v
    RE_used_v = pv_used_an_v + wt_used_an_v
    curt_pv_v = pv_pot_an_v - pv_used_an_v
    curt_wt_v = wt_pot_an_v - wt_used_an_v
    curt_tot_v = max(curt_pv_v + curt_wt_v, 0)
    curt_rate_v = curt_tot_v / max(RE_pot_v, 1e-9)

    carbon_v = 1000 * float(np.sum(Pg_mat * wd.EF * w[np.newaxis, :]))
    GEP_v    = (total_an_v - grid_an_v) / max(total_an_v, 1e-9)
    PUE_v    = total_an_v / max(IT_an_v, 1e-9)
    CUE_v    = carbon_v / max(IT_an_v * 1000, 1e-9)

    # Cost breakdown
    c_pv_v  = (CRF_pv * cfg.cap_cost_pv + cfg.om_pv) * Cpv_v
    c_wt_v  = (CRF_wt * cfg.cap_cost_wt + cfg.om_wt) * Cwt_v
    c_ba_v  = (CRF_ba * cfg.cap_cost_ba + cfg.om_rate_ba*cfg.cap_cost_ba) * Cba_v
    c_ct_v  = (CRF_ct * cfg.cap_cost_ct + cfg.om_rate_ct*cfg.cap_cost_ct) * Cct_v
    c_line_v = CRF_line * cfg.lineCapex
    grid_e_v = float(np.sum(td.price_MWh[:, np.newaxis] * Pg_mat * w[np.newaxis, :]))
    exp_rev_v = td.export_MWh * export_an_v
    cap_fee_v = capacityfee_fixed
    obj_cost_v = c_pv_v + c_wt_v + c_ba_v + c_ct_v + c_line_v + grid_e_v + cap_fee_v - exp_rev_v

    # Annual energy is in MWh; multiply by 1000 to convert denominator to kWh.
    LCOE_IT_v    = obj_cost_v / max(IT_an_v * 1000, 1)  # ¥/kWh
    LCOE_total_v = obj_cost_v / max(total_an_v * 1000, 1)
    LCOE_pv_v    = c_pv_v / max(pv_used_an_v * 1000, 1)
    LCOE_wt_v    = c_wt_v / max(wt_used_an_v * 1000, 1)

    capex_v  = (CRF_pv*cfg.cap_cost_pv*Cpv_v + CRF_wt*cfg.cap_cost_wt*Cwt_v +
                CRF_ba*cfg.cap_cost_ba*Cba_v + CRF_ct*cfg.cap_cost_ct*Cct_v + CRF_line*cfg.lineCapex)
    opex_v   = (cfg.om_pv*Cpv_v + cfg.om_wt*Cwt_v +
                cfg.om_rate_ba*cfg.cap_cost_ba*Cba_v + cfg.om_rate_ct*cfg.cap_cost_ct*Cct_v + grid_e_v + cap_fee_v)

    total_cost_v = obj_cost_v
    s_pv  = c_pv_v  / max(total_cost_v, 1e-9)
    s_wt  = c_wt_v  / max(total_cost_v, 1e-9)
    s_ba  = c_ba_v  / max(total_cost_v, 1e-9)
    s_ct  = c_ct_v  / max(total_cost_v, 1e-9)
    s_grd = (grid_e_v + cap_fee_v) / max(total_cost_v, 1e-9)
    s_ln  = c_line_v / max(total_cost_v, 1e-9)

    P_peak_base     = float(np.max(Pd_24x6))
    P_peak_shifted  = float(np.max(Ld_mat))
    dur_bess_base   = Cba_v / max(P_peak_base, 1e-9)
    dur_bess_shift  = Cba_v / max(P_peak_shifted, 1e-9)
    dur_ct_base     = Cct_v / max(P_peak_base, 1e-9)
    dur_ct_shift    = Cct_v / max(P_peak_shifted, 1e-9)

    efc_annual, efc_day = compute_bess_efc(Pba_c_mat, Pba_d_mat, Cba_v, w)
    green_h, green_sh   = compute_green_hours(Pg_mat, w, cfg.pg_zero_tol)

    r = GEPResult(
        z=z, GEP_target=s_target, GEP_actual=round(GEP_v, 6), feasible=True,
        Cpv=Cpv_v, Cwt=Cwt_v, Cba=Cba_v, Cct=Cct_v,
        P_peak_IT_base=P_peak_base, P_peak_IT_shifted=P_peak_shifted,
        Qch_cap_max=Qch_cap_max,
        GreenHours_actual=green_h, GreenHourShare_actual=green_sh,
        LCOE_IT=LCOE_IT_v, LCOE_total=LCOE_total_v,
        LCOE_pv=LCOE_pv_v, LCOE_wt=LCOE_wt_v,
        IT_demand_annual=IT_an_v, ChillerElec_annual=chiller_an_v,
        TotalElec_annual=total_an_v,
        Carbon_total_kgCO2e=carbon_v, PUE=PUE_v, CUE=CUE_v,
        pv_used_annual=pv_used_an_v, wt_used_annual=wt_used_an_v,
        pv_pot_annual=pv_pot_an_v, wt_pot_annual=wt_pot_an_v,
        RE_used_annual=RE_used_v, RE_pot_annual=RE_pot_v,
        CurtPV_annual=curt_pv_v, CurtWT_annual=curt_wt_v,
        CurtTot_annual=curt_tot_v, CurtRate=curt_rate_v,
        grid_annual=grid_an_v, export_annual=export_an_v,
        export_ratio=export_an_v/max(RE_pot_v,1e-9),
        ObjCost=obj_cost_v, CAPEX_total=capex_v, OPEX_total=opex_v,
        Cost_PV=c_pv_v, Cost_WT=c_wt_v, Cost_BA=c_ba_v, Cost_CT=c_ct_v,
        Cost_Line=c_line_v, Grid_energy_cost=grid_e_v,
        ExportRevenue=exp_rev_v, CapacityFee=cap_fee_v,
        Share_PV=s_pv, Share_WT=s_wt, Share_BA=s_ba,
        Share_CT=s_ct, Share_Grid=s_grd, Share_Line=s_ln,
        BESS_EFC_annual=efc_annual, BESS_EFC_day=efc_day,
        alpha=cfg.alpha,
        Dur_BESS_base=dur_bess_base, Dur_BESS_shifted=dur_bess_shift,
        Dur_CT_base=dur_ct_base, Dur_CT_shifted=dur_ct_shift,
        Peak_reduction_IT=P_peak_base-P_peak_shifted,
        Peak_reduction_IT_ratio=(P_peak_base-P_peak_shifted)/max(P_peak_base,1e-9),
        LoadStd_IT_base=float(np.std(Pd_24x6)), LoadStd_IT_shifted=float(np.std(Ld_mat)),
        MeanITLoad24h=float(np.mean(Pd_24x6[:,0])),
        solve_time=solve_time,
        Pg_mat=Pg_mat if write_dispatch else None,
        Ppv_use_mat=Ppv_mat if write_dispatch else None,
        Pwt_use_mat=Pwt_mat if write_dispatch else None,
        Pba_c_mat=Pba_c_mat if write_dispatch else None,
        Pba_d_mat=Pba_d_mat if write_dispatch else None,
        Eba_mat=Eba_mat if write_dispatch else None,
        Ld_IT_mat=Ld_mat if write_dispatch else None,
        Pch_tot_mat=Pch_tot_mat if write_dispatch else None,
        Pch_dir_mat=Pch_dir_mat if write_dispatch else None,
        Pch_charge_mat=Pch_ct_mat if write_dispatch else None,
        Qch_dir_mat=Qch_dir_mat if write_dispatch else None,
        Qct_c_mat=Qct_c_mat if write_dispatch else None,
        Qct_d_mat=Qct_d_mat if write_dispatch else None,
        Ect_mat=Ect_mat if write_dispatch else None,
        Pexp_mat=Pexp_mat if write_dispatch else None,
        Ppv_avail_mat=Ppv_avail_mat if write_dispatch else None,
        Pwt_avail_mat=Pwt_avail_mat if write_dispatch else None,
        Shift_out_mat=Shift_out_mat if write_dispatch else None,
        Shift_in_mat=Shift_in_mat if write_dispatch else None,
        COP_mat=COP_mat if write_dispatch else None,
    )
    return r


# ══════════════════════════════════════════════════════════
#  MAIN SOLVE FUNCTION
# ══════════════════════════════════════════════════════════

def solve_region(
    wd: WeatherData,
    td: TariffData,
    cfg: OptimizerConfig,
    write_dispatch: bool = False,
    progress_callback=None,
) -> Tuple[List[GEPResult], Dict[str, Any]]:
    """
    Main solver: run GEP scan for one region.
    Returns (scan_results, best_points).
    """
    if not HAS_PULP:
        raise ImportError("PuLP not installed. Run: pip install pulp")

    # Load profile
    d = wd.d.copy()
    mean_mw = float(np.mean(d))
    if cfg.load_profile != "raw":
        d = get_it_profile(cfg.load_profile, mean_mw)

    n_day = len(wd.w)
    Pd_24x6 = np.tile(d[:, np.newaxis], (1, n_day))
    P_peak_IT_base = float(np.max(Pd_24x6))

    # Pre-compute coefficients
    kp     = compute_pv_kp(wd.Tdb, wd.S, wd.vw, cfg.eps_pv)
    cf     = compute_wind_cf(wd.vw, cfg.vin, cfg.vr, cfg.vout)
    COP    = cop_from_twb(wd.Twb)
    invCOP = 1.0 / np.maximum(COP, 0.5)

    # Qch_cap_max
    use_flex = cfg.scenario == "S3"
    Qch_cap_max = cfg.Qch_cap_max_S3 if use_flex else cfg.chiller_cap_multiplier * P_peak_IT_base

    # Contracted demand & capacity fee (fixed, based on base peak)
    contracted_demand = 1.5 * P_peak_IT_base
    capacityfee_fixed = contracted_demand * td.fee_MW * 12  # ¥/yr

    # CRF factors
    CRF_pv   = crf(cfg.i_rate, cfg.n_pv)
    CRF_wt   = crf(cfg.i_rate, cfg.n_wt)
    CRF_ba   = crf(cfg.i_rate, cfg.n_ba)
    CRF_ct   = crf(cfg.i_rate, cfg.n_ct)
    CRF_line = crf(cfg.i_rate, cfg.n_line)

    results = []
    n_targets = len(cfg.gep_targets)

    for z, s_target in enumerate(cfg.gep_targets):
        if progress_callback:
            progress_callback(z, n_targets, s_target)

        result = _solve_one_gep_pulp(
            z+1, s_target, wd, td, cfg,
            kp, cf, invCOP, Qch_cap_max,
            contracted_demand, capacityfee_fixed, Pd_24x6,
            CRF_pv, CRF_wt, CRF_ba, CRF_ct, CRF_line,
            write_dispatch=write_dispatch,
        )
        result.GEP_max_target_feasible = s_target if result.feasible else None
        results.append(result)
        logger.info(f"z={z+1:2d} GEP={s_target:.2f} → "
                    f"{'LCOE={:.4f} GEP_act={:.3f}'.format(result.LCOE_IT, result.GEP_actual) if result.feasible else 'INFEASIBLE'}"
                    f" ({result.solve_time:.1f}s)")

    # ── Best points ──
    best = _compute_best_points(results, cfg.gep_targets)
    return results, best


def _compute_best_points(results: List[GEPResult], targets: List[float]) -> Dict[str, Any]:
    """Compute knee point, 80%, 100%, and free optimal."""
    feasible = [r for r in results if r.feasible and not math.isnan(r.LCOE_IT)]
    if not feasible:
        return {}

    # Feasible max
    feasible_target_max = max(r.GEP_target for r in feasible)
    feasible_actual_max = max(r.GEP_actual for r in feasible)

    # Knee: minimum LCOE_IT among feasible
    knee = min(feasible, key=lambda r: r.LCOE_IT)

    # 80% target
    r80  = min(feasible, key=lambda r: abs(r.GEP_actual - 0.80))
    r100 = min(feasible, key=lambda r: abs(r.GEP_actual - 1.00))
    rfree = min(feasible, key=lambda r: r.ObjCost)

    def bp(r, prefix):
        return {
            f"{prefix}_GEP": r.GEP_actual,
            f"{prefix}_GreenHours": r.GreenHours_actual,
            f"{prefix}_GreenHourShare": r.GreenHourShare_actual,
            f"LCOE_IT_{prefix}": r.LCOE_IT,
            f"LCOE_total_{prefix}": r.LCOE_total,
            f"Carbon_{prefix}": r.Carbon_total_kgCO2e,
            f"PUE_{prefix}": r.PUE,
            f"CUE_{prefix}": r.CUE,
            f"CurtRate_{prefix}": r.CurtRate,
        }

    best = {
        "FeasibleMax_TargetGEP": feasible_target_max,
        "FeasibleMax_ActualGEP": feasible_actual_max,
        "Knee_zTarget": knee.GEP_target,
        "Knee_GEP": knee.GEP_actual,
        "Knee_GreenHours": knee.GreenHours_actual,
        "Knee_GreenHourShare": knee.GreenHourShare_actual,
        "Knee_LCOE_IT": knee.LCOE_IT,
        "Knee_LCOE_total": knee.LCOE_total,
        "Knee_Carbon_total": knee.Carbon_total_kgCO2e,
        "Knee_PUE": knee.PUE,
        "Knee_CUE": knee.CUE,
        "Knee_CurtRate": knee.CurtRate,
        **bp(r80, "80"),
        **bp(r100, "100"),
        "GEP_80": r80.GEP_actual,
        "GEP_100": r100.GEP_actual,
        "Free_GEP": rfree.GEP_actual,
        "Free_GreenHours": rfree.GreenHours_actual,
        "Free_GreenHourShare": rfree.GreenHourShare_actual,
        "Free_LCOE_IT": rfree.LCOE_IT,
        "Free_LCOE_total": rfree.LCOE_total,
        "Free_Carbon_total": rfree.Carbon_total_kgCO2e,
        "Free_PUE": rfree.PUE,
        "Free_CUE": rfree.CUE,
        "Free_CurtRate": rfree.CurtRate,
        "Free_Export_annual": rfree.export_annual,
        "Free_ExportRevenue": rfree.ExportRevenue,
        "Free_Export_ratio_to_RE_potential": rfree.export_ratio,
        "Free_Ppeak_shifted": rfree.P_peak_IT_shifted,
        "Free_Dur_BESS_shifted": rfree.Dur_BESS_shifted,
        "Free_Dur_CT_shifted": rfree.Dur_CT_shifted,
        "Free_BESS_EFC_annual": rfree.BESS_EFC_annual,
        # knee extra
        "Knee_Cpv": knee.Cpv, "Knee_Cwt": knee.Cwt,
        "Knee_Cba": knee.Cba, "Knee_Cct": knee.Cct,
    }
    return best
