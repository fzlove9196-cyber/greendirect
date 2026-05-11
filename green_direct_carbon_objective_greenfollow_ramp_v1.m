%% ==================== 31省：S0/S1/S2/S3（含蓄冷+变COP）+ 政策场景A/B/C/C ====================
% 场景定义：
% S0：无储能、无算力灵活性、无热力灵活性（但有基础制冷，COP随湿球温度变化）
% S1：电力灵活性（电池储能）
% S2：电力+热力灵活性（电池储能+蓄冷，COP随湿球温度变化）
% S3：电力+热力+算力灵活性（电池储能+蓄冷+固定比例负荷转移）
%
% 关键口径：
% 1) 总用电 = IT用电 + 制冷耗电
% 2) 冷量需求 = IT负荷；制冷机COP由湿球温度决定
% 3) 制冷机总制冷量上限 = 1.5 × IT峰值负荷
% 4) GEP考核基数 = IT年耗电 + 空调实际年耗电
% 5) 容量电费固定按 1.5 × IT最大负荷 计收（不随优化变化）
% 6) 电池与蓄冷都只能用风/光绿电充能（严格到“充电功率+充冷对应电功率”层面）
% 7) S0场景不预设绿电占比上限：逐档扫描0~100%，不可行档位自动记为NaN，并输出最大可行GEP
%
% ===== 本次新增输出口径 =====
% CAPEX_total(¥/yr)：年化投资成本 = CRF × 初始投资（含PV/WT/BA/CT/Line）
% OPEX_total(¥/yr)：运维成本 = 设备运维费 + 电网购电费 + 容量电费
% BESS_EFC_annual(cycle/yr)：储能年等效完整循环次数 = Σ_j [w_j × 0.5×(充电量_j+放电量_j)/Cba]
% BESS_EFC_dayj(cycle/day)：第 j 个典型日的储能等效完整循环次数
% GreenHours_actual(h)：按典型日权重折算的全年绿电小时数（Pg <= 阈值）
% GreenHourShare_actual：GreenHours_actual / 8760
% Carbon_total(kgCO2e/yr)：总碳排放量 = Σ_j w_j × Σ_h Pg(h,j) × 1000 × EF(h,j)
% PUE：总能耗 / IT能耗 = (IT年耗电 + 制冷年耗电) / IT年耗电
% CUE：总碳排放量 / IT能耗，单位 kgCO2e/kWh_IT
% 可通过 OBJECTIVE_MODE 选择目标函数：总成本最小或总碳排放量最小

clear; clc;

%% =====【你只需要改这里】======
% 选择要跑的结果组合。每个组合显式包含：场景、S3可转移比例、政策、负荷、目标函数。
RUN_CASES = [ ...
    "S1_A_raw_cost", ...
    "S2_A_raw_cost", ...
    "S3_a10_A_raw_cost", ...
    "S3_a20_A_raw_cost", ...
    "S3_a30_A_raw_cost", ...
    "S3_a40_A_raw_cost", ...
    "S3_a50_A_raw_cost", ...
    "S3_a60_A_raw_cost", ...
    "S3_a50_A_raw_carbon" ...
    ];

% 负荷曲线开关（可灵活设置）
% "raw"        ：使用天气文件中 AD1:AD24 的原始基准负荷
% "flat"       ：持续高载型（训练 / HPC / 通用计算）
% "day_peak"   ：日间-晚间峰值型（推理 / 用户请求驱动）
% "night_bias" ：夜间偏置型（后台批量计算，对照场景）
% "dual_peak"  ：混合波动型（在线服务 + batch 混部）
%
% 示例：
%   LOAD_PROFILE_LIST = ["raw"];
%   LOAD_PROFILE_LIST = ["flat" "day_peak" "night_bias" "dual_peak"];
%   LOAD_PROFILE_LIST = ["raw" "flat" "day_peak" "night_bias" "dual_peak"];
LOAD_PROFILE_LIST = ["raw"];

% 目标函数选择：
% "cost"   ：最小化年总成本（原始目标函数）
% "carbon" ：最小化年总碳排放量 Carbon_total(kgCO2e/yr)
% 注意：不管选择哪种目标，都会同时输出成本、LCOE、总碳排放量、PUE、CUE。
% 本脚本会根据 RUN_CASES 自动覆盖 OBJECTIVE_MODE。
OBJECTIVE_MODE = "cost" ;

% 当 OBJECTIVE_MODE = "carbon" 时，默认采用“字典序”求解：
% 第一步先最小化总碳排放量；第二步在碳排放基本不增加的前提下最小化总成本。
% 这样可以避免纯碳目标下风光装机被求解器推到容量上限、导致 LCOE 虚高。
CARBON_LEXICOGRAPHIC = true;
carbon_lex_rel_tol = 1e-6;       % 第二步允许的相对碳排放松弛
carbon_lex_abs_tol_kg = 1e3;     % 第二步允许的绝对碳排放松弛，kgCO2e/yr

% 政策场景开关：
% A：原始基准场景（不新增政策约束）
% B：增加“弃电率 <= 40%%”约束，即 Curt_total_annual / RE_potential_annual <= 0.40
% C：预留（后续再补）
POLICY_SCENARIO = "A";

% 场景B参数
curt_rate_limit_B = 0.40;

% 场景C参数（在B基础上增加）
export_ratio_limit_C = 0.20;   % 年上网电量 <= 可用绿电年总量的20%

% S3 固定可转移比例（后续若你要单独写步长扫描版，再单开脚本）
alpha_fixed_S3 = 0.60;

% ===== S3新增固定容量约束 =====
% 仅对 S3 生效：IT负荷上限固定为 500 MW；制冷机总制冷量上限固定为其 1.5 倍
IT_load_cap_S3 = 500;                  % MW
Qch_cap_max_S3 = 1.5 * IT_load_cap_S3; % MW_th

% 省份范围
provWanted = 1:31;

% 输入文件
weatherFile = 'weather_31_Method0(2)_1.xlsx';
tariffFile  = 'tariff_out.xlsx';

% 是否输出逐档位调度表（sheet会很多）
writeDispatch = false;

% 新方法输出目录；若目标文件已存在，脚本会停止，避免覆盖旧结果。
RESULT_OUT_DIR = 'result_31prov_greenfollow_ramp';

% GEP扫描点
shares = 0:0.05:1.00;
tol    = 0.000000005;

% 绿电小时判定阈值：当 Pg <= pg_zero_tol 时，视为该时刻电网购电为 0
pg_zero_tol = 1e-6;   % MW
% 严格100%%绿电档位的年度购电近似零阈值：当 grid_annual <= grid_zero_tol_annual 时，视为年度完全不购电
grid_zero_tol_annual = 1e-6;   % MWh

% S3/cost 二阶段追绿电+平滑参数；S3/carbon 第三阶段仅使用平滑项。
ramp_weight = 0.25;
cost_tie_rel_tol = 1e-4;
cost_tie_abs_tol = 1e3;

%% ---------- 0) 政策场景解析 ----------
POLICY_SCENARIO = upper(string(POLICY_SCENARIO));
switch POLICY_SCENARIO
    case "A"
        use_curt_limit = false;
        curt_rate_limit = nan;
        use_export = false;
        export_ratio_limit = nan;
        policy_desc = "基准政策场景A：不新增政策约束";
    case "B"
        use_curt_limit = true;
        curt_rate_limit = curt_rate_limit_B;
        use_export = false;
        export_ratio_limit = nan;
        policy_desc = sprintf("政策场景B：弃电率 <= %.0f%%", curt_rate_limit*100);
    case "C"
        use_curt_limit = true;
        curt_rate_limit = curt_rate_limit_B;
        use_export = true;
        export_ratio_limit = export_ratio_limit_C;
        policy_desc = sprintf("政策场景C：弃电率 <= %.0f%% + 年上网电量 <= 可用绿电的%.0f%%", curt_rate_limit*100, export_ratio_limit*100);
    otherwise
        error('未知政策场景：%s。请设为 "A"、"B" 或 "C"。', POLICY_SCENARIO);
end

fprintf('当前政策场景：%s\n', policy_desc);

% ---------- 0.1) 负荷曲线列表解析 ----------
LOAD_PROFILE_LIST = string(LOAD_PROFILE_LIST);
if isempty(LOAD_PROFILE_LIST)
    error('LOAD_PROFILE_LIST 不能为空。');
end
validLoadProfiles = ["raw" "flat" "day_peak" "night_bias" "dual_peak"];
for ii = 1:numel(LOAD_PROFILE_LIST)
    if ~any(strcmpi(LOAD_PROFILE_LIST(ii), validLoadProfiles))
        error('未知负荷曲线类型：%s', LOAD_PROFILE_LIST(ii));
    end
end
LOAD_PROFILE_LIST = lower(LOAD_PROFILE_LIST);
fprintf('当前将计算的负荷曲线：%s\n', strjoin(cellstr(LOAD_PROFILE_LIST), ', '));

% ---------- 0.2) 目标函数与运行组合解析 ----------
validObjectiveModes = ["cost" "carbon"];
RUN_CASES = string(RUN_CASES);
if isempty(RUN_CASES)
    error('RUN_CASES 不能为空。');
end
if ~exist(RESULT_OUT_DIR, 'dir')
    mkdir(RESULT_OUT_DIR);
end
fprintf('当前将计算的组合：%s\n', strjoin(cellstr(RUN_CASES), ', '));
fprintf('新结果输出目录：%s\n', RESULT_OUT_DIR);

%% ---------- 1) 预读取电价数据（只读一次） ----------
fprintf('正在读取 31 省电价数据...\n');
[~,sheetNames] = xlsfinfo(tariffFile); sheetNames = string(sheetNames);

if any(strcmpi(sheetNames,"Tariff_with_headers"))
    P  = readmatrix(tariffFile, 'Sheet','Tariff_with_headers', 'Range','B2:Y200');
    F  = readmatrix(tariffFile, 'Sheet','Tariff_with_headers', 'Range','Z2:Z200');
    EP = readmatrix(tariffFile, 'Sheet','Tariff_with_headers', 'Range','AA2:AA200');
    valid = ~all(isnan(P),2);
    priceMatAll_kWh    = P(valid,:);
    feeAll_kWmon       = F(valid,:);
    exportPriceAll_kWh = EP(valid,:);
elseif any(strcmpi(sheetNames,"Tariff31x24"))
    priceMatAll_kWh    = readmatrix(tariffFile, 'Sheet','Tariff31x24', 'Range','A1:X100');
    feeAll_kWmon       = readmatrix(tariffFile, 'Sheet','Tariff31x24', 'Range','Z1:Z100');
    exportPriceAll_kWh = readmatrix(tariffFile, 'Sheet','Tariff31x24', 'Range','AA1:AA100');
else
    error('在 %s 中未找到 "Tariff_with_headers" 或 "Tariff31x24"。', tariffFile);
end

if size(priceMatAll_kWh, 1) < max(provWanted)
    warning('电价数据行数 (%d) 小于请求的省份数 (%d)，将只计算现有行数。', size(priceMatAll_kWh,1), max(provWanted));
    provWanted = provWanted(provWanted <= size(priceMatAll_kWh,1));
end

assert(size(priceMatAll_kWh,2)==24, '电价矩阵需为 N×24');
priceMat_kWh    = priceMatAll_kWh(provWanted,:);
feePerKW       = feeAll_kWmon(provWanted);
exportPrice_kWh = exportPriceAll_kWh(provWanted);

% 单位统一：¥/MWh，¥/MW/月
priceMat_MWh    = priceMat_kWh    * 1000;
feePerMW        = feePerKW        * 1000;
exportPrice_MWh = exportPrice_kWh * 1000;

%% ---------- 2) 识别天气文件省份sheet ----------
[~,wxSheets] = xlsfinfo(weatherFile); wxSheets = string(wxSheets);
provSheets = strings(1,numel(provWanted));
for idx = 1:numel(provWanted)
    i = provWanted(idx);
    s1 = sprintf('Prov%02d', i); s2 = sprintf('Prov%d', i);
    if any(wxSheets == s1)
        provSheets(idx) = s1;
    elseif any(wxSheets == s2)
        provSheets(idx) = s2;
    else
        error('在 %s 中未找到 Prov%02d 或 Prov%d', weatherFile, i, i);
    end
end
numProv = numel(provSheets);
numZ    = numel(shares);
fprintf('已识别 %d 个省份 Sheet，准备开始计算。\n', numProv);

%% ==================== 3) 负荷曲线 × 场景循环 ====================
for lp = 1:numel(LOAD_PROFILE_LIST)
    LOAD_PROFILE = lower(string(LOAD_PROFILE_LIST(lp)));
    load_profile_code = get_load_profile_code(LOAD_PROFILE);
    load_profile_desc = get_load_profile_desc(LOAD_PROFILE);

    fprintf('\n######################################################\n');
    fprintf('当前负荷曲线：%s（%s）\n', LOAD_PROFILE, load_profile_desc);
    fprintf('######################################################\n');

for case_idx = 1:numel(RUN_CASES)
    CASE_NAME = string(RUN_CASES(case_idx));

    switch CASE_NAME
        case "S1_A_raw_cost"
            SCEN = "S1"; case_alpha_list = 0; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S2_A_raw_cost"
            SCEN = "S2"; case_alpha_list = 0; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a10_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.10; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a20_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.20; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a30_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.30; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a40_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.40; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a50_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.50; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a60_A_raw_cost"
            SCEN = "S3"; case_alpha_list = 0.60; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "cost";
        case "S3_a50_A_raw_carbon"
            SCEN = "S3"; case_alpha_list = 0.50; case_policy = "A"; case_load_profile = "raw"; OBJECTIVE_MODE = "carbon";
        otherwise
            error('未知运行组合：%s', CASE_NAME);
    end

    if case_load_profile ~= LOAD_PROFILE
        continue;
    end
    if case_policy ~= POLICY_SCENARIO
        error('运行组合 %s 要求政策=%s，但当前 POLICY_SCENARIO=%s。', CASE_NAME, case_policy, POLICY_SCENARIO);
    end

    OBJECTIVE_MODE = lower(string(OBJECTIVE_MODE));
    if ~any(OBJECTIVE_MODE == validObjectiveModes)
        error('未知目标函数模式：%s。请设为 "cost" 或 "carbon"。', OBJECTIVE_MODE);
    end
    if OBJECTIVE_MODE == "cost"
        objective_desc = "目标函数：年总成本最小";
    else
        if CARBON_LEXICOGRAPHIC
            objective_desc = "目标函数：年总碳排放量最小，并以总成本最小作为二级目标，最终进行负荷平滑";
        else
            objective_desc = "目标函数：年总碳排放量最小";
        end
    end
    fprintf('\n>>> 运行组合：%s；目标函数模式：%s（%s）\n', CASE_NAME, OBJECTIVE_MODE, objective_desc);

    % 场景开关
    switch SCEN
        case "S0"
            use_storage      = false;
            use_cold_storage = false;
            use_flex         = false;
            alpha_list       = case_alpha_list;
        case "S1"
            use_storage      = true;
            use_cold_storage = false;
            use_flex         = false;
            alpha_list       = case_alpha_list;
        case "S2"
            use_storage      = true;
            use_cold_storage = true;
            use_flex         = false;
            alpha_list       = case_alpha_list;
        case "S3"
            use_storage      = true;
            use_cold_storage = true;
            use_flex         = true;
            alpha_list       = case_alpha_list;
        otherwise
            error('未知场景：%s', SCEN);
    end

    for aa = 1:numel(alpha_list)
        alpha = alpha_list(aa);

        fprintf('\n======================================================\n');
        if use_flex
            fprintf('开始计算场景：%s（固定 alpha = %.0f%%，政策=%s，负荷=%s）\n', SCEN, alpha*100, POLICY_SCENARIO, LOAD_PROFILE);
        else
            fprintf('开始计算场景：%s（政策=%s，负荷=%s）\n', SCEN, POLICY_SCENARIO, LOAD_PROFILE);
        end
        fprintf('======================================================\n');

        if OBJECTIVE_MODE == "carbon"
            method_suffix = 'ramp';
        else
            method_suffix = 'greenfollow_ramp';
        end
        if use_flex
            suffix = sprintf('_a%02d', round(alpha*100));
            fileStem = sprintf('%s%s_%s_%s_%s_%s', SCEN, suffix, POLICY_SCENARIO, LOAD_PROFILE, OBJECTIVE_MODE, method_suffix);
        else
            fileStem = sprintf('%s_%s_%s_%s_%s', SCEN, POLICY_SCENARIO, LOAD_PROFILE, OBJECTIVE_MODE, method_suffix);
        end
        outFile   = fullfile(RESULT_OUT_DIR, ['result_31prov_' fileStem '.xlsx']);
        cloudFile = fullfile(RESULT_OUT_DIR, ['cloud_31prov_'  fileStem '.xlsx']);

        if exist(outFile,'file') || exist(cloudFile,'file')
            error('目标输出文件已存在，将停止以避免覆盖：%s / %s', outFile, cloudFile);
        end

        %% ---------- 参数区 ----------
        % 风机功率曲线
        vin = 3; vr = 12; vout = 25;

        % 光伏温度修正
        eps_pv = -0.0006;

        % 折现率
        i_rate = 0.06;

        % 寿命（年）
        n_pv = 20; n_wt = 20; n_ba = 7; n_ct = 20; n_line = 15;

        % CRF（分设备）
        CRF_pv = i_rate/(1-(1+i_rate)^(-n_pv));
        CRF_wt = i_rate/(1-(1+i_rate)^(-n_wt));
        CRF_ba = i_rate/(1-(1+i_rate)^(-n_ba));
        CRF_ct = i_rate/(1-(1+i_rate)^(-n_ct));
        CRF_line = i_rate/(1-(1+i_rate)^(-n_line));

        % 成本参数（单位统一到 MW / MWh / MWh_th）
        cap_cost_wt = 4500 * 1000;                % ¥/kW -> ¥/MW
        om_wt       = 100  * 1000;                % ¥/kW·yr -> ¥/MW·yr

        cap_cost_pv = 3080 * 1000;                % ¥/kW -> ¥/MW
        om_pv       = 70   * 1000;                % ¥/kW·yr -> ¥/MW·yr

        cap_cost_ba = 1400 * 1000;                % ¥/kWh -> ¥/MWh
        om_ba       = 0.005 * cap_cost_ba;        % 0.5%投资/年

        cap_cost_ct = 222  * 1000;                % ¥/kWh_th -> ¥/MWh_th
        om_ct       = 0.007 * cap_cost_ct;        % 0.7%投资/年

        % 线路投资（保留）
        lineCapex = 2e8;                          % ¥

        % 容量上限
        CpvMax = 1e6;
        CwtMax = 1e6;
        if use_storage
            Cba_max = 1e6;                        % MWh
        else
            Cba_max = 0;
        end
        if use_cold_storage
            Cct_max = 1e6;                        % MWh_th
        else
            Cct_max = 0;
        end

        % 电池参数
        eta_ba = 0.95;
        p_ratio_ba = 0.2;
        SOCmin_ba = 0.1; SOCmax_ba = 0.9; SOC0_ba = 0.5;
        M_p_ba = p_ratio_ba * max(Cba_max,1);

        % 蓄冷参数
        eta_ct = 0.95;
        p_ratio_ct = 0.2;
        SOCmin_ct = 0.1; SOCmax_ct = 0.9; SOC0_ct = 0.5;
        M_p_ct = p_ratio_ct * max(Cct_max,1);

        % 算力转移窗口（S3沿用旧程序）
        flex_windows = [2 5 8 12];
        nb = numel(flex_windows);
        assert(alpha >= -1e-12 && alpha <= 1+1e-12, 'alpha 必须在 [0,1]');

        %% ---------- 输出表头 ----------
        summaryHeader = { ...
            'z', ...
            'Cpv(MW)','Cwt(MW)','Cba(MWh)','Cct(MWh_th)', ...
            'P_peak_IT_base(MW)','P_peak_IT_shifted(MW)', ...
            'Qch_cap_max(MW_th)', ...
            'GEP_actual','GEP_target','GEP_max_target_feasible', ...
            'GreenHours_actual(h)','GreenHourShare_actual', ...
            'LCOE_IT(¥/kWh_IT)','LCOE_total(¥/kWh_total)', ...
            'LCOE_pv(¥/kWh)','LCOE_wt(¥/kWh)', ...
            'IT_demand_annual(MWh)','ChillerElec_annual(MWh)','TotalElec_annual(MWh)', ...
            'Carbon_total(kgCO2e/yr)','PUE','CUE(kgCO2e/kWh_IT)', ...
            'pv_used_annual(MWh)','wt_used_annual(MWh)', ...
            'pv_potential_annual(MWh)','wt_potential_annual(MWh)', ...
            'RE_used_annual(MWh)','RE_potential_annual(MWh)', ...
            'Curt_PV_annual(MWh)','Curt_WT_annual(MWh)','Curt_total_annual(MWh)','Curt_rate', ...
            'grid_annual(MWh)','export_annual(MWh)','export_ratio_to_RE_potential', ...
            'Cost_PV(¥/yr)','Cost_WT(¥/yr)','Cost_BA(¥/yr)','Cost_CT(¥/yr)','ExportRevenue(¥/yr)', ...
            'Cost_GridEnergy(¥/yr)','Cost_CapacityFee(¥/yr)','Cost_Line(¥/yr)', ...
            'CAPEX_total(¥/yr)','OPEX_total(¥/yr)', ...
            'BESS_EFC_annual(cycle/yr)', ...
            'BESS_EFC_day1(cycle/day)','BESS_EFC_day2(cycle/day)','BESS_EFC_day3(cycle/day)', ...
            'BESS_EFC_day4(cycle/day)','BESS_EFC_day5(cycle/day)','BESS_EFC_day6(cycle/day)', ...
            'Share_PV','Share_WT','Share_BA','Share_CT','Share_Grid','Share_Line', ...
            'alpha', ...
            'Dur_BESS_base(h)','Dur_BESS_shifted(h)', ...
            'Dur_CT_base(h_th)','Dur_CT_shifted(h_th)', ...
            'Peak_reduction_IT(MW)','Peak_reduction_IT_ratio', ...
            'LoadStd_IT_base','LoadStd_IT_shifted', ...
            'LoadProfileCode','MeanITLoad24h(MW)' ...
            };

        dispatchHeader = { ...
            'season','hour','TypicalDayWeight(d/yr)','Tdb','Twb','COP', ...
            'Load_IT_base','Load_IT_shifted','Shift_out','Shift_in', ...
            'Cool_demand','Qch_direct','Qct_charge','Qct_discharge','E_ct', ...
            'Pch_direct','Pch_charge','Pch_total', ...
            'Ppv_use','Pwt_use','Ppv_avail','Pwt_avail', ...
            'Pg','CarbonFactor(kgCO2e/kWh)','GridCarbonContribution(kgCO2e/yr)', ...
            'Pexp','Pba_c','Pba_d','E_ba', ...
            'IsGreenHour','GreenHourContribution(h/yr)' ...
            };

        for p_idx = 1:numProv
            sh_name = provSheets(p_idx);
            writecell(summaryHeader, outFile, 'Sheet', sh_name + "_Summary", 'Range','A1');
        end

        %% ---------- cloud缓存 ----------
        cloudLCOE_IT    = nan(numProv, numZ);
        cloudLCOE_total = nan(numProv, numZ);
        cloudGEP        = nan(numProv, numZ);
        cloudCurtRate   = nan(numProv, numZ);
        cloudCpv        = nan(numProv, numZ);
        cloudCwt        = nan(numProv, numZ);
        cloudCba        = nan(numProv, numZ);
        cloudCct        = nan(numProv, numZ);
        cloudCurtTot    = nan(numProv, numZ);
        cloudChillerEle = nan(numProv, numZ);
        cloudTotalEle   = nan(numProv, numZ);
        cloudCarbonKg   = nan(numProv, numZ);
        cloudPUE        = nan(numProv, numZ);
        cloudCUE        = nan(numProv, numZ);
        cloudGEPTarget  = nan(numProv, numZ);

        cloudPpeakShift   = nan(numProv, numZ);
        cloudDurBESShift  = nan(numProv, numZ);
        cloudDurCTShift   = nan(numProv, numZ);
        cloudGreenHours   = nan(numProv, numZ);
        cloudGreenHourShare = nan(numProv, numZ);

        % ===== 新增：CAPEX / OPEX 矩阵 =====
        cloudCAPEX         = nan(numProv, numZ);
        cloudOPEX          = nan(numProv, numZ);
        cloudExportAnnual  = nan(numProv, numZ);
        cloudExportRevenue = nan(numProv, numZ);
        cloudExportRatio   = nan(numProv, numZ);
        cloudBessEFCAnnual = nan(numProv, numZ);
        cloudBessEFCDay    = nan(numProv, numZ, 6);

        free_LCOE_IT       = nan(numProv,1);
        free_LCOE_total   = nan(numProv,1);
        free_CarbonKg     = nan(numProv,1);
        free_PUE          = nan(numProv,1);
        free_CUE          = nan(numProv,1);
        free_GEP          = nan(numProv,1);
        free_CurtRate     = nan(numProv,1);
        free_PpeakShift      = nan(numProv,1);
        free_DurBESShift    = nan(numProv,1);
        free_DurCTShift     = nan(numProv,1);
        free_GreenHours     = nan(numProv,1);
        free_GreenHourShare = nan(numProv,1);
        free_ExportAnnual   = nan(numProv,1);
        free_ExportRevenue = nan(numProv,1);
        free_ExportRatio   = nan(numProv,1);
        free_BessEFCAnnual = nan(numProv,1);
        free_BessEFCDay    = nan(numProv,6);

        feasibleTargetMax = nan(numProv,1);
        feasibleActualMax = nan(numProv,1);

        meta = { 'Scenario', char(SCEN); ...
                 'PolicyScenario', char(POLICY_SCENARIO); ...
                 'PolicyDescription', char(policy_desc); ...
                 'LoadProfile', char(LOAD_PROFILE); ...
                 'LoadProfileDescription', char(load_profile_desc); ...
                 'LoadProfileCode', load_profile_code; ...
                 'ObjectiveMode', char(OBJECTIVE_MODE); ...
                 'ObjectiveDescription', char(objective_desc); ...
                 'OptimizationMethod', method_suffix; ...
                 'RampWeight', ramp_weight; ...
                 'CostTieRelTol', cost_tie_rel_tol; ...
                 'CostTieAbsTol', cost_tie_abs_tol; ...
                 'CarbonLexicographic', CARBON_LEXICOGRAPHIC; ...
                 'CarbonLexRelTol', carbon_lex_rel_tol; ...
                 'CarbonLexAbsTolKg', carbon_lex_abs_tol_kg; ...
                 'CarbonFactorRange', 'AF1:AK24 in weatherFile, unit kgCO2e/kWh'; ...
                 'CarbonAccounting', 'Carbon_total = sum_j w_j * sum_h Pg(h,j) * 1000 * EF(h,j); export is not credited'; ...
                 'PUE_definition', 'PUE = TotalElec_annual / IT_demand_annual'; ...
                 'CUE_definition', 'CUE = Carbon_total_kg / (IT_demand_annual * 1000), kgCO2e/kWh_IT'; ...
                 'CurtRateLimit', curt_rate_limit; ...
                 'UseExport', use_export; ...
                 'ExportRatioLimit', export_ratio_limit; ...
                 'alpha', alpha; ...
                 'use_storage', use_storage; ...
                 'use_cold_storage', use_cold_storage; ...
                 'use_flex', use_flex; ...
                 'BESS_EFC_definition', '0.5*(charge+discharge)/Cba, annual by typical-day weights'; ...
                 'GreenHour_definition', 'annual green hours by weighted typical days, counted when Pg <= pg_zero_tol'; ...
                 'pg_zero_tol(MW)', pg_zero_tol; ...
                 'grid_zero_tol_annual(MWh)', grid_zero_tol_annual; ...
                 'shares_step', shares(2)-shares(1); ...
                 'tol', tol; ...
                 'strict_100pct_rule', 'for the last 100% target only, enforce grid_annual <= grid_zero_tol_annual instead of +/- tol band' };
        writecell(meta, cloudFile, 'Sheet','Meta', 'Range','A1');

        t_case = tic;

        %% ==================== 逐省求解 ====================
        for p = 1:numProv
            sh = provSheets(p);
            fprintf('--> [%s] 省 %d/%d：%s ... ', SCEN, p, numProv, sh);
            t_prov = tic;

            try
                % weather_31_Method0.xlsx:
                % 干球温度 A:F；湿球温度 H:M；辐照 O:T；风速 V:AA；Weights AC1:AC6；IT负荷 AD1:AD24
                Tdb = xlsread(weatherFile, sh, 'A1:F24');
                Twb = xlsread(weatherFile, sh, 'H1:M24');
                S   = xlsread(weatherFile, sh, 'O1:T24');
                vw  = xlsread(weatherFile, sh, 'V1:AA24');
                w   = xlsread(weatherFile, sh, 'AC1:AC6'); w = w(:);
                numTyp = numel(w);
                d   = xlsread(weatherFile, sh, 'AD1:AD24');
                EF_kg_per_kWh = xlsread(weatherFile, sh, 'AF1:AK24');  % 小时级电网碳排放因子，kgCO2e/kWh

                if any(size(EF_kg_per_kWh) ~= [24 6])
                    error('碳排放因子 AF1:AK24 的维度应为 24×6。');
                end
                if any(~isfinite(EF_kg_per_kWh(:)))
                    error('碳排放因子 AF1:AK24 存在 NaN/Inf，请检查输入文件。');
                end

                % 按所选负荷曲线重塑 24h IT 负荷，保持原始平均 IT 负荷不变
                meanLoadMW_raw = mean(d);
                if strcmpi(LOAD_PROFILE, "raw")
                    d = d(:);
                else
                    d = get_it_profile(LOAD_PROFILE, meanLoadMW_raw);
                end
            catch ME
                fprintf('❌ 读取失败，跳过。%s\n', ME.message);
                continue;
            end

            price = priceMat_MWh(p,:).';
            feeZ  = feePerMW(p);
            exportPrice = exportPrice_MWh(p);

            % 基准 IT 负荷
            Pd_24x6 = repmat(d,1,6);
            P_peak_IT_base = max(Pd_24x6(:));
            IT_demand_annual_base = sum(sum(Pd_24x6,1) .* w.');
            LoadStd_IT_base = std(Pd_24x6(:));
            MeanITLoad24h = mean(d);

            % 固定容量电费：按 1.5 × IT最大负荷
            contracted_demand = 1.5 * P_peak_IT_base;
            capacityfee_fixed = contracted_demand * feeZ * 12;

            % 制冷机总制冷量上限：S3固定为 1.5 × 500 MW，其余场景保持原口径
            if use_flex
                Qch_cap_max = Qch_cap_max_S3;
            else
                Qch_cap_max = 1.5 * P_peak_IT_base;
            end

            % COP（直接由湿球温度决定）
            COP    = cop_from_twb(Twb);
            COP    = max(COP, 0.5);          % 数值保护
            invCOP = 1 ./ COP;

            % 风机可用出力系数
            cf = zeros(24,6);
            for t = 1:24
                for j = 1:6
                    if vw(t,j) < vin || vw(t,j) >= vout
                        cf(t,j) = 0;
                    elseif vw(t,j) >= vr
                        cf(t,j) = 1;
                    else
                        cf(t,j) = (vw(t,j)^3 - vin^3) / (vr^3 - vin^3);
                    end
                end
            end

            % 光伏可用出力系数
            Tm = Tdb + 0.0138.*S.*(1 - 0.042.*vw).*(1 + 0.031.*Tdb);
            kp = (S .* (1 + eps_pv*(Tm - 25))) / 1000;

            %% ========== (A) 分档求解：z = 1..numZ ==========
            for z = 1:numZ
                yalmip('clear');
                s_target = shares(z);

                % 决策变量
                Cpv = sdpvar(1,1);
                Cwt = sdpvar(1,1);
                Cba = sdpvar(1,1);
                Cct = sdpvar(1,1);
                y_line = binvar(1,1);

                Pg      = sdpvar(24,6);
                Pexp    = sdpvar(24,6);
                Ppv_use = sdpvar(24,6);
                Pwt_use = sdpvar(24,6);

                % 电池
                Pba_c = sdpvar(24,6);
                Pba_d = sdpvar(24,6);
                Eba   = sdpvar(24,6);
                z_ba_c = binvar(24,6);
                z_ba_d = binvar(24,6);

                % 制冷与蓄冷
                Qch_dir = sdpvar(24,6);       % 直接供冷量
                Qct_c   = sdpvar(24,6);       % 充冷量（由制冷机额外产冷进入蓄冷）
                Qct_d   = sdpvar(24,6);       % 放冷量
                Ect     = sdpvar(24,6);
                z_ct_c  = binvar(24,6);
                z_ct_d  = binvar(24,6);

                if use_flex
                    Xcell = cell(nb, max(flex_windows)+1);
                else
                    Xcell = {};
                end

                % 派生变量（电功率）
                Pch_dir = Qch_dir .* invCOP;
                Pch_ct  = Qct_c   .* invCOP;
                Pch_tot = Pch_dir + Pch_ct;

                st = [];

                % 容量边界
                st = [st, 0 <= Cpv <= CpvMax, 0 <= Cwt <= CwtMax, 0 <= Cba <= Cba_max, 0 <= Cct <= Cct_max];
                st = [st, Cpv <= CpvMax * y_line, Cwt <= CwtMax * y_line];

                % 风光利用
                Ppv_avail = Cpv .* kp;
                Pwt_avail = Cwt .* cf;
                st = [st, 0 <= Ppv_use <= Ppv_avail];
                st = [st, 0 <= Pwt_use <= Pwt_avail];

                % 电网购电 / 上网
                st = [st, 0 <= Pg(:) <= 1e5];
                st = [st, 0 <= Pexp];

                % 电池
                st = [st, z_ba_c + z_ba_d <= 1];
                st = [st, 0 <= Pba_c <= p_ratio_ba*Cba, 0 <= Pba_d <= p_ratio_ba*Cba];
                st = [st, Pba_c <= M_p_ba * z_ba_c, Pba_d <= M_p_ba * z_ba_d];
                st = [st, SOCmin_ba*Cba <= Eba(:) <= SOCmax_ba*Cba];
                st = [st, Eba(1,:) == SOC0_ba*Cba - Pba_d(1,:)/eta_ba + eta_ba*Pba_c(1,:)];
                for t = 2:24
                    st = [st, Eba(t,:) == Eba(t-1,:) - Pba_d(t,:)/eta_ba + eta_ba*Pba_c(t,:)];
                end
                st = [st, Eba(24,:) == SOC0_ba*Cba];

                % 蓄冷
                st = [st, z_ct_c + z_ct_d <= 1];
                st = [st, 0 <= Qct_c <= p_ratio_ct*Cct, 0 <= Qct_d <= p_ratio_ct*Cct];
                st = [st, Qct_c <= M_p_ct * z_ct_c, Qct_d <= M_p_ct * z_ct_d];
                st = [st, SOCmin_ct*Cct <= Ect(:) <= SOCmax_ct*Cct];
                st = [st, Ect(1,:) == SOC0_ct*Cct - Qct_d(1,:)/eta_ct + eta_ct*Qct_c(1,:)];
                for t = 2:24
                    st = [st, Ect(t,:) == Ect(t-1,:) - Qct_d(t,:)/eta_ct + eta_ct*Qct_c(t,:)];
                end
                st = [st, Ect(24,:) == SOC0_ct*Cct];

                % 若场景关闭某类灵活性，则强制归零
                if ~use_storage
                    st = [st, Cba == 0, Pba_c == 0, Pba_d == 0, Eba == 0, z_ba_c == 0, z_ba_d == 0];
                end
                if ~use_cold_storage
                    st = [st, Cct == 0, Qct_c == 0, Qct_d == 0, Ect == 0, z_ct_c == 0, z_ct_d == 0];
                end

                % 算力时移（仅S3）
                if use_flex
                    share_per_class = alpha / nb;
                    for bi = 1:nb
                        b = flex_windows(bi);
                        sumX = 0;
                        for tau = 0:b
                            Xt = sdpvar(24,6,'full');
                            Xcell{bi, tau+1} = Xt;
                            st = [st, 0 <= Xt];
                            sumX = sumX + Xt;
                        end
                        st = [st, sumX == share_per_class * Pd_24x6];
                    end

                    Received = 0;
                    for bi = 1:nb
                        b = flex_windows(bi);
                        for tau = 0:b
                            Xt = Xcell{bi, tau+1};
                            if tau == 0
                                Xshift = Xt;
                            else
                                Xshift = [Xt(24-tau+1:24,:); Xt(1:24-tau,:)];
                            end
                            Received = Received + Xshift;
                        end
                    end
                    Ld_IT = (1 - alpha) * Pd_24x6 + Received;
                    Shift_out_24x6 = alpha * Pd_24x6;
                    Shift_in_24x6  = Received;
                else
                    Ld_IT = Pd_24x6;
                    Shift_out_24x6 = zeros(24,6);
                    Shift_in_24x6  = zeros(24,6);
                end

                % S3固定IT负荷上限（其余场景不加此约束）
                if use_flex
                    st = [st, Ld_IT <= IT_load_cap_S3];
                end

                % 冷量平衡：冷量需求 = IT负荷
                st = [st, 0 <= Qch_dir, 0 <= Qch_dir + Qct_c <= Qch_cap_max];
                st = [st, Qch_dir + Qct_d == Ld_IT];

                % 绿电充能约束（电池充电 + 蓄冷充冷对应电耗 <= 风光利用）
                st = [st, Pba_c + Pch_ct <= Ppv_use + Pwt_use];

                % 上网约束：只能使用未在本地利用的可用绿电进行反送电
                st = [st, Pexp <= (Ppv_avail - Ppv_use) + (Pwt_avail - Pwt_use)];

                % 电力平衡：IT + 制冷耗电 + 上网电量 = 供给侧
                st = [st, Ld_IT + Pch_tot + Pexp == Pg + Ppv_use + Pwt_use + Pba_d - Pba_c];

                % 年度统计
                IT_demand_annual = (sum(Ld_IT,1) * w);
                chillerElec_annual = (sum(Pch_tot,1) * w);
                totalElec_annual   = IT_demand_annual + chillerElec_annual;

                pv_used_annual = (sum(Ppv_use,1) * w);
                wt_used_annual = (sum(Pwt_use,1) * w);
                grid_annual    = (sum(Pg,1)      * w);
                export_annual  = (sum(Pexp,1)    * w);

                pv_pot_annual  = (sum(Ppv_avail,1) * w);
                wt_pot_annual  = (sum(Pwt_avail,1) * w);
                RE_used_annual = pv_used_annual + wt_used_annual;
                RE_pot_annual  = pv_pot_annual + wt_pot_annual;

                CurtPV_annual  = (sum(Ppv_avail - Ppv_use,1) * w);
                CurtWT_annual  = (sum(Pwt_avail - Pwt_use,1) * w);
                CurtTot_annual = CurtPV_annual + CurtWT_annual;

                % 政策场景约束
                if use_curt_limit
                    st = [st, CurtTot_annual <= curt_rate_limit * RE_pot_annual];
                end
                if use_export
                    st = [st, export_annual <= export_ratio_limit * RE_pot_annual];
                else
                    st = [st, Pexp == 0];
                end

                % GEP约束：基于总实际耗电（IT + 制冷）
                if abs(s_target - 0) < 1e-12
                    st = [st, Cpv == 0, Cwt == 0, Cba == 0, Cct == 0];
                    st = [st, Ppv_use == 0, Pwt_use == 0, Pexp == 0, Pba_c == 0, Pba_d == 0, Eba == 0, z_ba_c == 0, z_ba_d == 0];
                    st = [st, Qct_c == 0, Qct_d == 0, Ect == 0, z_ct_c == 0, z_ct_d == 0];
                    st = [st, Ld_IT + Pch_tot == Pg];
                elseif abs(s_target - 1) < 1e-12
                    % 最后一个100%%绿电挡位：取消比例容差带，单独强制年度购电近似为0
                    st = [st, 0 <= grid_annual <= grid_zero_tol_annual];
                else
                    lbG = max(0, s_target - tol);
                    ubG = min(1, s_target + tol);
                    st = [st, (1-ubG)*totalElec_annual <= grid_annual <= (1-lbG)*totalElec_annual];
                end

                % 目标函数：投资 + 运维 + 总电费 + 固定容量电费
                Cost_PV = CRF_pv * Cpv * cap_cost_pv + Cpv * om_pv;
                Cost_WT = CRF_wt * Cwt * cap_cost_wt + Cwt * om_wt;
                Cost_BA = CRF_ba * Cba * cap_cost_ba + Cba * om_ba;
                Cost_CT = CRF_ct * Cct * cap_cost_ct + Cct * om_ct;
                Cost_Line = lineCapex * CRF_line * y_line;

                Grid_energy_cost = (price.' * Pg) * w;
                ExportRevenue    = exportPrice * export_annual;
                CapacityFee = capacityfee_fixed;

                ObjCost = Cost_PV + Cost_WT + Cost_BA + Cost_CT + Cost_Line + Grid_energy_cost + CapacityFee - ExportRevenue;

                % ===== 新增：总碳排放量目标函数/输出表达式 =====
                % Pg 单位 MW，典型日每个时段为 1 h，因此 Pg 对应 MWh；
                % EF_kg_per_kWh 单位 kgCO2e/kWh，故需乘以 1000 kWh/MWh。
                Carbon_total_kg = 1000 * (sum(Pg .* EF_kg_per_kWh, 1) * w);
                if OBJECTIVE_MODE == "cost"
                    ObjSelect = ObjCost;
                else
                    ObjSelect = Carbon_total_kg;
                end

                % ===== 新增：CAPEX / OPEX 表达式 =====
                CAPEX_total = ...
                    CRF_pv   * Cpv * cap_cost_pv + ...
                    CRF_wt   * Cwt * cap_cost_wt + ...
                    CRF_ba   * Cba * cap_cost_ba + ...
                    CRF_ct   * Cct * cap_cost_ct + ...
                    CRF_line * lineCapex * y_line;

                OPEX_total = ...
                    Cpv * om_pv + ...
                    Cwt * om_wt + ...
                    Cba * om_ba + ...
                    Cct * om_ct + ...
                    Grid_energy_cost + ...
                    CapacityFee;

                % 真实LCOE（两种口径都核算）
                LCOE_IT_MWh    = ObjCost / IT_demand_annual;
                LCOE_total_MWh = ObjCost / totalElec_annual;

                ops = sdpsettings('verbose',0,'solver','gurobi','showprogress',0,'warning',0, ...
                                  'gurobi.TimeLimit',3000, 'gurobi.MIPGap',5e-3);

                rowIdx = z + 1;
                if OBJECTIVE_MODE == "cost"
                    sol = optimize(st, ObjCost, ops);
                    if use_flex && sol.problem == 0
                        ObjCost_min_follow = value(ObjCost);
                        Cpv_follow = value(Cpv);
                        Cwt_follow = value(Cwt);
                        Cba_follow = value(Cba);
                        Cct_follow = value(Cct);
                        y_line_follow = round(value(y_line));

                        RE_avail_follow = value(Ppv_avail + Pwt_avail);
                        GreenIndex_follow = RE_avail_follow ./ max(max(RE_avail_follow(:)), 1e-9);
                        W24_follow = repmat(w.', 24, 1);
                        FollowReward = sum(sum(W24_follow .* GreenIndex_follow .* Shift_in_24x6));

                        RampAbs_follow = sdpvar(23, numTyp, 'full');
                        W23_follow = repmat(w.', 23, 1);
                        RampPenalty = sum(sum(W23_follow .* RampAbs_follow));

                        cost_allowance_follow = max(cost_tie_abs_tol, abs(ObjCost_min_follow) * cost_tie_rel_tol);
                        FollowReward_ref = max(1, abs(value(FollowReward)));
                        Ld_IT_first_follow = value(Ld_IT);
                        RampPenalty_ref = max(1, sum(sum(W23_follow .* abs(Ld_IT_first_follow(2:24,:) - Ld_IT_first_follow(1:23,:)))));

                        st_follow = [st, ...
                            Cpv == Cpv_follow, Cwt == Cwt_follow, Cba == Cba_follow, Cct == Cct_follow, y_line == y_line_follow, ...
                            ObjCost <= ObjCost_min_follow + cost_allowance_follow, ...
                            RampAbs_follow >= Ld_IT(2:24,:) - Ld_IT(1:23,:), ...
                            RampAbs_follow >= -(Ld_IT(2:24,:) - Ld_IT(1:23,:))];

                        FollowRampObjective = -(FollowReward / FollowReward_ref) + ramp_weight * (RampPenalty / RampPenalty_ref);
                        sol_follow = optimize(st_follow, FollowRampObjective, ops);
                        if sol_follow.problem == 0
                            sol = sol_follow;
                        else
                            warning('Green-follow+ramp second-stage solve failed at z=%d, province=%s; restoring cost-optimal solve.', z, char(sh));
                            sol = optimize(st, ObjCost, ops);
                        end
                    end
                else
                    if CARBON_LEXICOGRAPHIC
                        sol_carbon = optimize(st, Carbon_total_kg, ops);
                        if sol_carbon.problem ~= 0
                            sol = sol_carbon;
                        else
                            carbon_min_val = value(Carbon_total_kg);
                            carbon_allowance = max(carbon_lex_abs_tol_kg, abs(carbon_min_val) * carbon_lex_rel_tol);
                            st_carbon_lex = [st, Carbon_total_kg <= carbon_min_val + carbon_allowance];
                            sol_cost_carbon = optimize(st_carbon_lex, ObjCost, ops);
                            sol = sol_cost_carbon;
                            if use_flex && sol_cost_carbon.problem == 0
                                ObjCost_min_smooth = value(ObjCost);
                                Cpv_smooth = value(Cpv);
                                Cwt_smooth = value(Cwt);
                                Cba_smooth = value(Cba);
                                Cct_smooth = value(Cct);
                                y_line_smooth = round(value(y_line));

                                cost_allowance_smooth = max(cost_tie_abs_tol, abs(ObjCost_min_smooth) * cost_tie_rel_tol);
                                RampAbs_smooth = sdpvar(23, numTyp, 'full');
                                W23_smooth = repmat(w.', 23, 1);
                                RampPenalty = sum(sum(W23_smooth .* RampAbs_smooth));

                                st_smooth = [st_carbon_lex, ...
                                    Cpv == Cpv_smooth, Cwt == Cwt_smooth, Cba == Cba_smooth, Cct == Cct_smooth, y_line == y_line_smooth, ...
                                    ObjCost <= ObjCost_min_smooth + cost_allowance_smooth, ...
                                    RampAbs_smooth >= Ld_IT(2:24,:) - Ld_IT(1:23,:), ...
                                    RampAbs_smooth >= -(Ld_IT(2:24,:) - Ld_IT(1:23,:))];

                                sol_smooth = optimize(st_smooth, RampPenalty, ops);
                                if sol_smooth.problem == 0
                                    sol = sol_smooth;
                                else
                                    warning('Carbon ramp third-stage solve failed at z=%d, province=%s; restoring carbon-cost solve.', z, char(sh));
                                    sol_restore = optimize(st_carbon_lex, ObjCost, ops);
                                    if sol_restore.problem == 0
                                        sol = sol_restore;
                                    end
                                end
                            end
                        end
                    else
                        sol = optimize(st, Carbon_total_kg, ops);
                    end
                end

                if sol.problem ~= 0
                    writematrix([z, nan(1, numel(summaryHeader)-1)], outFile, 'Sheet', sh + "_Summary", 'Range', sprintf('A%d', rowIdx));
                    continue;
                end

                % 取值
                Cpv_val = value(Cpv); Cwt_val = value(Cwt); Cba_val = value(Cba); Cct_val = value(Cct);
                Pg_val_mat = value(Pg);
                [GreenHours_actual, GreenHourShare_actual, GreenHourFlag, GreenHourContribution] = compute_green_hours(Pg_val_mat, w, pg_zero_tol);
                grid_val = value(grid_annual);
                export_val = value(export_annual);
                IT_annual_val = value(IT_demand_annual);
                chillerElec_val = value(chillerElec_annual);
                totalElec_val = value(totalElec_annual);
                Carbon_total_kg_val = value(Carbon_total_kg);
                PUE_val = totalElec_val / max(IT_annual_val, 1e-9);
                CUE_val = Carbon_total_kg_val / max(IT_annual_val * 1000, 1e-9);

                GEP_actual = (totalElec_val - grid_val) / max(totalElec_val, 1e-9);
                LCOE_IT_kWh    = value(LCOE_IT_MWh)    / 1000;
                LCOE_total_kWh = value(LCOE_total_MWh) / 1000;

                pv_used_val = value(pv_used_annual);
                wt_used_val = value(wt_used_annual);
                pv_pot_val  = value(pv_pot_annual);
                wt_pot_val  = value(wt_pot_annual);
                RE_used_val = value(RE_used_annual);
                RE_pot_val  = value(RE_pot_annual);

                CurtPV_val  = value(CurtPV_annual);
                CurtWT_val  = value(CurtWT_annual);
                CurtTot_val = value(CurtTot_annual);
                Curt_rate   = CurtTot_val / max(RE_pot_val, 1e-9);
                export_ratio_to_RE_potential = export_val / max(RE_pot_val, 1e-9);

                pv_eps = max(pv_used_val, 1e-9);
                wt_eps = max(wt_used_val, 1e-9);
                LCOE_pv_kWh = ((CRF_pv*Cpv_val*cap_cost_pv + Cpv_val*om_pv)/pv_eps)/1000;
                LCOE_wt_kWh = ((CRF_wt*Cwt_val*cap_cost_wt + Cwt_val*om_wt)/wt_eps)/1000;

                Cost_PV_val = value(Cost_PV);
                Cost_WT_val = value(Cost_WT);
                Cost_BA_val = value(Cost_BA);
                Cost_CT_val = value(Cost_CT);
                Cost_Line_val = value(Cost_Line);
                Grid_energy_cost_val = value(Grid_energy_cost);
                ExportRevenue_val    = value(ExportRevenue);
                CapacityFee_val = CapacityFee;

                % ===== 新增：CAPEX / OPEX 数值 =====
                CAPEX_total_val = value(CAPEX_total);
                OPEX_total_val  = value(OPEX_total);

                total_cost = Cost_PV_val + Cost_WT_val + Cost_BA_val + Cost_CT_val + Cost_Line_val + Grid_energy_cost_val + CapacityFee_val;
                Share_PV   = (total_cost>0) * Cost_PV_val / total_cost;
                Share_WT   = (total_cost>0) * Cost_WT_val / total_cost;
                Share_BA   = (total_cost>0) * Cost_BA_val / total_cost;
                Share_CT   = (total_cost>0) * Cost_CT_val / total_cost;
                Share_Grid = (total_cost>0) * (Grid_energy_cost_val + CapacityFee_val) / total_cost;
                Share_Line = (total_cost>0) * Cost_Line_val / total_cost;

                if isa(Ld_IT,'sdpvar')
                    Ld_IT_val = value(Ld_IT);
                else
                    Ld_IT_val = Ld_IT;
                end
                P_peak_IT_shifted = max(Ld_IT_val(:));
                LoadStd_IT_shifted = std(Ld_IT_val(:));
                Peak_red = P_peak_IT_base - P_peak_IT_shifted;
                Peak_red_ratio = Peak_red / max(P_peak_IT_base,1e-9);

                Dur_BESS_base = Cba_val / max(P_peak_IT_base,1e-9);
                Dur_BESS_shifted = Cba_val / max(P_peak_IT_shifted,1e-9);
                Dur_CT_base = Cct_val / max(P_peak_IT_base,1e-9);
                Dur_CT_shifted = Cct_val / max(P_peak_IT_shifted,1e-9);

                [BESS_EFC_annual, BESS_EFC_day] = compute_bess_efc(value(Pba_c), value(Pba_d), Cba_val, w);

                summary_row = [ ...
                    z, ...
                    Cpv_val, Cwt_val, Cba_val, Cct_val, ...
                    P_peak_IT_base, P_peak_IT_shifted, ...
                    Qch_cap_max, ...
                    GEP_actual, s_target, nan, ...
                    GreenHours_actual, GreenHourShare_actual, ...
                    LCOE_IT_kWh, LCOE_total_kWh, ...
                    LCOE_pv_kWh, LCOE_wt_kWh, ...
                    IT_annual_val, chillerElec_val, totalElec_val, ...
                    Carbon_total_kg_val, PUE_val, CUE_val, ...
                    pv_used_val, wt_used_val, ...
                    pv_pot_val, wt_pot_val, ...
                    RE_used_val, RE_pot_val, ...
                    CurtPV_val, CurtWT_val, CurtTot_val, Curt_rate, ...
                    grid_val, export_val, export_ratio_to_RE_potential, ...
                    Cost_PV_val, Cost_WT_val, Cost_BA_val, Cost_CT_val, ExportRevenue_val, ...
                    Grid_energy_cost_val, CapacityFee_val, Cost_Line_val, ...
                    CAPEX_total_val, OPEX_total_val, ...
                    BESS_EFC_annual, BESS_EFC_day, ...
                    Share_PV, Share_WT, Share_BA, Share_CT, Share_Grid, Share_Line, ...
                    alpha, ...
                    Dur_BESS_base, Dur_BESS_shifted, ...
                    Dur_CT_base, Dur_CT_shifted, ...
                    Peak_red, Peak_red_ratio, ...
                    LoadStd_IT_base, LoadStd_IT_shifted, ...
                    load_profile_code, MeanITLoad24h ...
                    ];
                writematrix(summary_row, outFile, 'Sheet', sh + "_Summary", 'Range', sprintf('A%d', rowIdx));

                % cloud缓存
                cloudLCOE_IT(p,z)    = LCOE_IT_kWh;
                cloudLCOE_total(p,z) = LCOE_total_kWh;
                cloudGEP(p,z)        = GEP_actual;
                cloudCurtRate(p,z)   = Curt_rate;
                cloudCpv(p,z)        = Cpv_val;
                cloudCwt(p,z)        = Cwt_val;
                cloudCba(p,z)        = Cba_val;
                cloudCct(p,z)        = Cct_val;
                cloudCurtTot(p,z)    = CurtTot_val;
                cloudChillerEle(p,z) = chillerElec_val;
                cloudTotalEle(p,z)   = totalElec_val;
                cloudCarbonKg(p,z)   = Carbon_total_kg_val;
                cloudPUE(p,z)        = PUE_val;
                cloudCUE(p,z)        = CUE_val;
                cloudGEPTarget(p,z)      = s_target;
                cloudPpeakShift(p,z)     = P_peak_IT_shifted;
                cloudDurBESShift(p,z)    = Dur_BESS_shifted;
                cloudDurCTShift(p,z)     = Dur_CT_shifted;
                cloudGreenHours(p,z)     = GreenHours_actual;
                cloudGreenHourShare(p,z) = GreenHourShare_actual;

                % ===== 新增：CAPEX / OPEX 缓存 =====
                cloudCAPEX(p,z)         = CAPEX_total_val;
                cloudOPEX(p,z)          = OPEX_total_val;
                cloudExportAnnual(p,z)  = export_val;
                cloudExportRevenue(p,z) = ExportRevenue_val;
                cloudExportRatio(p,z)   = export_ratio_to_RE_potential;
                cloudBessEFCAnnual(p,z) = BESS_EFC_annual;
                cloudBessEFCDay(p,z,:)  = reshape(BESS_EFC_day, 1, 1, []);

                % 逐省最大可行目标GEP
                tmp1 = [feasibleTargetMax(p), s_target];
                tmp1 = tmp1(~isnan(tmp1));
                feasibleTargetMax(p) = max(tmp1);
                tmp2 = [feasibleActualMax(p), GEP_actual];
                tmp2 = tmp2(~isnan(tmp2));
                feasibleActualMax(p) = max(tmp2);

                % 可选调度输出
                if writeDispatch
                    if isa(Ppv_avail,'sdpvar'), Ppv_av_val = value(Ppv_avail); else, Ppv_av_val = Ppv_avail; end
                    if isa(Pwt_avail,'sdpvar'), Pwt_av_val = value(Pwt_avail); else, Pwt_av_val = Pwt_avail; end
                    if isa(Shift_in_24x6,'sdpvar'), Shift_in_val = value(Shift_in_24x6); else, Shift_in_val = Shift_in_24x6; end
                    Shift_out_val = Shift_out_24x6;

                    outMat = [ ...
                        reshape(repmat(1:6,24,1),[],1), repmat((1:24).',6,1), reshape(repmat(w.',24,1),[],1), ...
                        reshape(Tdb,[],1), reshape(Twb,[],1), reshape(COP,[],1), ...
                        reshape(Pd_24x6,[],1), reshape(Ld_IT_val,[],1), ...
                        reshape(Shift_out_val,[],1), reshape(Shift_in_val,[],1), ...
                        reshape(Ld_IT_val,[],1), ...
                        reshape(value(Qch_dir),[],1), reshape(value(Qct_c),[],1), reshape(value(Qct_d),[],1), reshape(value(Ect),[],1), ...
                        reshape(value(Pch_dir),[],1), reshape(value(Pch_ct),[],1), reshape(value(Pch_tot),[],1), ...
                        reshape(value(Ppv_use),[],1), reshape(value(Pwt_use),[],1), reshape(Ppv_av_val,[],1), reshape(Pwt_av_val,[],1), ...
                        reshape(Pg_val_mat,[],1), reshape(EF_kg_per_kWh,[],1), reshape(Pg_val_mat .* EF_kg_per_kWh .* repmat(w.',24,1) * 1000,[],1), ...
                        reshape(value(Pexp),[],1), reshape(value(Pba_c),[],1), reshape(value(Pba_d),[],1), reshape(value(Eba),[],1), ...
                        reshape(GreenHourFlag,[],1), reshape(GreenHourContribution,[],1) ...
                        ];
                    dsheet = sprintf('%s_z%02d_Dispatch', sh, z);
                    writecell(dispatchHeader, outFile, 'Sheet', dsheet, 'Range','A1');
                    writematrix(outMat, outFile, 'Sheet', dsheet, 'Range','A2');
                end
            end

            %% ========== (B) 自由最优：不设GEP约束（写到z=0） ==========
            yalmip('clear');

            Cpv = sdpvar(1,1);
            Cwt = sdpvar(1,1);
            Cba = sdpvar(1,1);
            Cct = sdpvar(1,1);
            y_line = binvar(1,1);

            Pg      = sdpvar(24,6);
            Pexp    = sdpvar(24,6);
            Ppv_use = sdpvar(24,6);
            Pwt_use = sdpvar(24,6);

            Pba_c = sdpvar(24,6); Pba_d = sdpvar(24,6); Eba = sdpvar(24,6);
            z_ba_c = binvar(24,6); z_ba_d = binvar(24,6);

            Qch_dir = sdpvar(24,6);
            Qct_c   = sdpvar(24,6); Qct_d = sdpvar(24,6); Ect = sdpvar(24,6);
            z_ct_c  = binvar(24,6); z_ct_d = binvar(24,6);

            Pch_dir = Qch_dir .* invCOP;
            Pch_ct  = Qct_c   .* invCOP;
            Pch_tot = Pch_dir + Pch_ct;

            st = [];
            st = [st, 0 <= Cpv <= CpvMax, 0 <= Cwt <= CwtMax, 0 <= Cba <= Cba_max, 0 <= Cct <= Cct_max];
            st = [st, Cpv <= CpvMax * y_line, Cwt <= CwtMax * y_line];

            Ppv_avail = Cpv .* kp;
            Pwt_avail = Cwt .* cf;
            st = [st, 0 <= Ppv_use <= Ppv_avail];
            st = [st, 0 <= Pwt_use <= Pwt_avail];
            st = [st, 0 <= Pg(:) <= 1e5];
            st = [st, 0 <= Pexp];

            st = [st, z_ba_c + z_ba_d <= 1];
            st = [st, 0 <= Pba_c <= p_ratio_ba*Cba, 0 <= Pba_d <= p_ratio_ba*Cba];
            st = [st, Pba_c <= M_p_ba * z_ba_c, Pba_d <= M_p_ba * z_ba_d];
            st = [st, SOCmin_ba*Cba <= Eba(:) <= SOCmax_ba*Cba];
            st = [st, Eba(1,:) == SOC0_ba*Cba - Pba_d(1,:)/eta_ba + eta_ba*Pba_c(1,:)];
            for t = 2:24
                st = [st, Eba(t,:) == Eba(t-1,:) - Pba_d(t,:)/eta_ba + eta_ba*Pba_c(t,:)];
            end
            st = [st, Eba(24,:) == SOC0_ba*Cba];

            st = [st, z_ct_c + z_ct_d <= 1];
            st = [st, 0 <= Qct_c <= p_ratio_ct*Cct, 0 <= Qct_d <= p_ratio_ct*Cct];
            st = [st, Qct_c <= M_p_ct * z_ct_c, Qct_d <= M_p_ct * z_ct_d];
            st = [st, SOCmin_ct*Cct <= Ect(:) <= SOCmax_ct*Cct];
            st = [st, Ect(1,:) == SOC0_ct*Cct - Qct_d(1,:)/eta_ct + eta_ct*Qct_c(1,:)];
            for t = 2:24
                st = [st, Ect(t,:) == Ect(t-1,:) - Qct_d(t,:)/eta_ct + eta_ct*Qct_c(t,:)];
            end
            st = [st, Ect(24,:) == SOC0_ct*Cct];

            if ~use_storage
                st = [st, Cba == 0, Pba_c == 0, Pba_d == 0, Eba == 0, z_ba_c == 0, z_ba_d == 0];
            end
            if ~use_cold_storage
                st = [st, Cct == 0, Qct_c == 0, Qct_d == 0, Ect == 0, z_ct_c == 0, z_ct_d == 0];
            end

            if use_flex
                Xcell = cell(nb, max(flex_windows)+1);
                share_per_class = alpha / nb;
                for bi = 1:nb
                    b = flex_windows(bi);
                    sumX = 0;
                    for tau = 0:b
                        Xt = sdpvar(24,6,'full');
                        Xcell{bi, tau+1} = Xt;
                        st = [st, 0 <= Xt];
                        sumX = sumX + Xt;
                    end
                    st = [st, sumX == share_per_class * Pd_24x6];
                end
                Received = 0;
                for bi = 1:nb
                    b = flex_windows(bi);
                    for tau = 0:b
                        Xt = Xcell{bi, tau+1};
                        if tau == 0
                            Xshift = Xt;
                        else
                            Xshift = [Xt(24-tau+1:24,:); Xt(1:24-tau,:)];
                        end
                        Received = Received + Xshift;
                    end
                end
                Ld_IT = (1 - alpha) * Pd_24x6 + Received;
            else
                Ld_IT = Pd_24x6;
            end

            if use_flex
                st = [st, Ld_IT <= IT_load_cap_S3];
            end

            st = [st, 0 <= Qch_dir, 0 <= Qch_dir + Qct_c <= Qch_cap_max];
            st = [st, Qch_dir + Qct_d == Ld_IT];
            st = [st, Pba_c + Pch_ct <= Ppv_use + Pwt_use];
            st = [st, Pexp <= (Ppv_avail - Ppv_use) + (Pwt_avail - Pwt_use)];
            st = [st, Ld_IT + Pch_tot + Pexp == Pg + Ppv_use + Pwt_use + Pba_d - Pba_c];

            IT_demand_annual = (sum(Ld_IT,1) * w);
            chillerElec_annual = (sum(Pch_tot,1) * w);
            totalElec_annual = IT_demand_annual + chillerElec_annual;
            pv_used_annual = (sum(Ppv_use,1) * w);
            wt_used_annual = (sum(Pwt_use,1) * w);
            grid_annual    = (sum(Pg,1)      * w);
            export_annual  = (sum(Pexp,1)    * w);
            pv_pot_annual  = (sum(Ppv_avail,1) * w);
            wt_pot_annual  = (sum(Pwt_avail,1) * w);
            RE_pot_annual  = pv_pot_annual + wt_pot_annual;
            CurtPV_annual  = (sum(Ppv_avail - Ppv_use,1) * w);
            CurtWT_annual  = (sum(Pwt_avail - Pwt_use,1) * w);
            CurtTot_annual = CurtPV_annual + CurtWT_annual;

            % 政策场景约束
            if use_curt_limit
                st = [st, CurtTot_annual <= curt_rate_limit * RE_pot_annual];
            end
            if use_export
                st = [st, export_annual <= export_ratio_limit * RE_pot_annual];
            else
                st = [st, Pexp == 0];
            end

            Cost_PV = CRF_pv * Cpv * cap_cost_pv + Cpv * om_pv;
            Cost_WT = CRF_wt * Cwt * cap_cost_wt + Cwt * om_wt;
            Cost_BA = CRF_ba * Cba * cap_cost_ba + Cba * om_ba;
            Cost_CT = CRF_ct * Cct * cap_cost_ct + Cct * om_ct;
            Cost_Line = lineCapex * CRF_line * y_line;
            Grid_energy_cost = (price.' * Pg) * w;
            ExportRevenue    = exportPrice * export_annual;
            CapacityFee = capacityfee_fixed;
            ObjCost = Cost_PV + Cost_WT + Cost_BA + Cost_CT + Cost_Line + Grid_energy_cost + CapacityFee - ExportRevenue;

            % ===== 新增：总碳排放量目标函数/输出表达式 =====
            % Pg 单位 MW，典型日每个时段为 1 h，因此 Pg 对应 MWh；
            % EF_kg_per_kWh 单位 kgCO2e/kWh，故需乘以 1000 kWh/MWh。
            Carbon_total_kg = 1000 * (sum(Pg .* EF_kg_per_kWh, 1) * w);
            if OBJECTIVE_MODE == "cost"
                ObjSelect = ObjCost;
            else
                ObjSelect = Carbon_total_kg;
            end

            % ===== 新增：CAPEX / OPEX 表达式 =====
            CAPEX_total = ...
                CRF_pv   * Cpv * cap_cost_pv + ...
                CRF_wt   * Cwt * cap_cost_wt + ...
                CRF_ba   * Cba * cap_cost_ba + ...
                CRF_ct   * Cct * cap_cost_ct + ...
                CRF_line * lineCapex * y_line;

            OPEX_total = ...
                Cpv * om_pv + ...
                Cwt * om_wt + ...
                Cba * om_ba + ...
                Cct * om_ct + ...
                Grid_energy_cost + ...
                CapacityFee;

            LCOE_IT_MWh    = ObjCost / IT_demand_annual;
            LCOE_total_MWh = ObjCost / totalElec_annual;

            ops = sdpsettings('verbose',0,'solver','gurobi','showprogress',0,'warning',0, ...
                              'gurobi.TimeLimit',3000, 'gurobi.MIPGap',5e-3);

            if OBJECTIVE_MODE == "cost"
                sol = optimize(st, ObjCost, ops);
            else
                if CARBON_LEXICOGRAPHIC
                    sol_carbon = optimize(st, Carbon_total_kg, ops);
                    if sol_carbon.problem ~= 0
                        sol = sol_carbon;
                    else
                        carbon_min_val = value(Carbon_total_kg);
                        carbon_allowance = max(carbon_lex_abs_tol_kg, abs(carbon_min_val) * carbon_lex_rel_tol);
                        st_carbon_lex = [st, Carbon_total_kg <= carbon_min_val + carbon_allowance];
                        sol = optimize(st_carbon_lex, ObjCost, ops);
                    end
                else
                    sol = optimize(st, Carbon_total_kg, ops);
                end
            end

            if sol.problem == 0
                Cpv_val = value(Cpv); Cwt_val = value(Cwt); Cba_val = value(Cba); Cct_val = value(Cct);
                Pg_val_mat = value(Pg);
                [GreenHours_actual, GreenHourShare_actual, ~, ~] = compute_green_hours(Pg_val_mat, w, pg_zero_tol);
                IT_annual_val = value(IT_demand_annual);
                totalElec_val = value(totalElec_annual);
                Carbon_total_kg_val = value(Carbon_total_kg);
                PUE_val = totalElec_val / max(IT_annual_val, 1e-9);
                CUE_val = Carbon_total_kg_val / max(IT_annual_val * 1000, 1e-9);
                grid_val = value(grid_annual);
                export_val = value(export_annual);
                CurtTot_val = value(CurtTot_annual);
                RE_pot_val  = value(RE_pot_annual);
                Curt_rate = CurtTot_val / max(RE_pot_val, 1e-9);
                export_ratio_to_RE_potential = export_val / max(RE_pot_val, 1e-9);

                GEP_actual = (totalElec_val - grid_val) / max(totalElec_val,1e-9);
                free_LCOE_IT(p)    = value(LCOE_IT_MWh)/1000;
                free_LCOE_total(p) = value(LCOE_total_MWh)/1000;
                free_CarbonKg(p)   = Carbon_total_kg_val;
                free_PUE(p)        = PUE_val;
                free_CUE(p)        = CUE_val;
                free_GEP(p)        = GEP_actual;
                free_CurtRate(p)   = Curt_rate;
                free_ExportAnnual(p)  = export_val;
                free_ExportRatio(p)   = export_ratio_to_RE_potential;
                free_ExportRevenue(p) = value(ExportRevenue);

                if isa(Ld_IT,'sdpvar')
                    Ld_IT_val = value(Ld_IT);
                else
                    Ld_IT_val = Ld_IT;
                end
                P_peak_IT_shifted = max(Ld_IT_val(:));
                free_PpeakShift(p)      = P_peak_IT_shifted;
                free_DurBESShift(p)    = Cba_val / max(P_peak_IT_shifted,1e-9);
                free_DurCTShift(p)     = Cct_val / max(P_peak_IT_shifted,1e-9);
                free_GreenHours(p)     = GreenHours_actual;
                free_GreenHourShare(p) = GreenHourShare_actual;

                row_out = numZ + 2;
                pv_used_val = value(pv_used_annual); wt_used_val = value(wt_used_annual);
                pv_pot_val  = value(pv_pot_annual);  wt_pot_val  = value(wt_pot_annual);
                RE_used_val = pv_used_val + wt_used_val;
                CurtPV_val  = value(CurtPV_annual);  CurtWT_val  = value(CurtWT_annual);
                chillerElec_val = value(chillerElec_annual);

                pv_eps = max(pv_used_val,1e-9); wt_eps = max(wt_used_val,1e-9);
                LCOE_pv_kWh = ((CRF_pv*Cpv_val*cap_cost_pv + Cpv_val*om_pv)/pv_eps)/1000;
                LCOE_wt_kWh = ((CRF_wt*Cwt_val*cap_cost_wt + Cwt_val*om_wt)/wt_eps)/1000;

                Cost_PV_val = value(Cost_PV); Cost_WT_val = value(Cost_WT); Cost_BA_val = value(Cost_BA);
                Cost_CT_val = value(Cost_CT); Cost_Line_val = value(Cost_Line); Grid_energy_cost_val = value(Grid_energy_cost);
                ExportRevenue_val = value(ExportRevenue);
                CapacityFee_val = CapacityFee;

                % ===== 新增：CAPEX / OPEX 数值 =====
                CAPEX_total_val = value(CAPEX_total);
                OPEX_total_val  = value(OPEX_total);

                total_cost = Cost_PV_val + Cost_WT_val + Cost_BA_val + Cost_CT_val + Cost_Line_val + Grid_energy_cost_val + CapacityFee_val;
                Share_PV   = (total_cost>0) * Cost_PV_val / total_cost;
                Share_WT   = (total_cost>0) * Cost_WT_val / total_cost;
                Share_BA   = (total_cost>0) * Cost_BA_val / total_cost;
                Share_CT   = (total_cost>0) * Cost_CT_val / total_cost;
                Share_Grid = (total_cost>0) * (Grid_energy_cost_val + CapacityFee_val) / total_cost;
                Share_Line = (total_cost>0) * Cost_Line_val / total_cost;

                LoadStd_IT_shifted = std(Ld_IT_val(:));
                Peak_red = P_peak_IT_base - P_peak_IT_shifted;
                Peak_red_ratio = Peak_red / max(P_peak_IT_base,1e-9);
                Dur_BESS_base = Cba_val / max(P_peak_IT_base,1e-9);
                Dur_BESS_shifted = Cba_val / max(P_peak_IT_shifted,1e-9);
                Dur_CT_base = Cct_val / max(P_peak_IT_base,1e-9);
                Dur_CT_shifted = Cct_val / max(P_peak_IT_shifted,1e-9);

                [BESS_EFC_annual, BESS_EFC_day] = compute_bess_efc(value(Pba_c), value(Pba_d), Cba_val, w);
                free_BessEFCAnnual(p) = BESS_EFC_annual;
                free_BessEFCDay(p,:)  = BESS_EFC_day;

                summary_row = [ ...
                    0, ...
                    Cpv_val, Cwt_val, Cba_val, Cct_val, ...
                    P_peak_IT_base, P_peak_IT_shifted, ...
                    Qch_cap_max, ...
                    GEP_actual, nan, feasibleTargetMax(p), ...
                    GreenHours_actual, GreenHourShare_actual, ...
                    free_LCOE_IT(p), free_LCOE_total(p), ...
                    LCOE_pv_kWh, LCOE_wt_kWh, ...
                    IT_annual_val, chillerElec_val, totalElec_val, ...
                    Carbon_total_kg_val, PUE_val, CUE_val, ...
                    pv_used_val, wt_used_val, ...
                    pv_pot_val, wt_pot_val, ...
                    RE_used_val, (pv_pot_val+wt_pot_val), ...
                    CurtPV_val, CurtWT_val, CurtTot_val, Curt_rate, ...
                    grid_val, export_val, export_ratio_to_RE_potential, ...
                    Cost_PV_val, Cost_WT_val, Cost_BA_val, Cost_CT_val, ExportRevenue_val, ...
                    Grid_energy_cost_val, CapacityFee_val, Cost_Line_val, ...
                    CAPEX_total_val, OPEX_total_val, ...
                    BESS_EFC_annual, BESS_EFC_day, ...
                    Share_PV, Share_WT, Share_BA, Share_CT, Share_Grid, Share_Line, ...
                    alpha, ...
                    Dur_BESS_base, Dur_BESS_shifted, ...
                    Dur_CT_base, Dur_CT_shifted, ...
                    Peak_red, Peak_red_ratio, ...
                    LoadStd_IT_base, LoadStd_IT_shifted, ...
                    load_profile_code, MeanITLoad24h ...
                    ];
                writematrix(summary_row, outFile, 'Sheet', sh + "_Summary", 'Range', sprintf('A%d', row_out));
            end

            % 回填Summary中的“GEP_max_target_feasible”列（第11列）
            try
                if ~isnan(feasibleTargetMax(p))
                    writematrix(repmat(feasibleTargetMax(p), numZ+1, 1), outFile, 'Sheet', sh + "_Summary", 'Range', sprintf('K2:K%d', numZ+2));
                end
            catch
            end

            fprintf('OK (%.1fs)\n', toc(t_prov));
        end % province loop

        %% ==================== 4) 输出 cloud.xlsx ====================
        hdr = [{'Prov'}, arrayfun(@(x) sprintf('%.0f%%', x*100), shares, 'uni', 0)];

        writecell(hdr, cloudFile, 'Sheet','LCOE_IT_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','LCOE_IT_matrix', 'Range','A2');
        writematrix(cloudLCOE_IT, cloudFile, 'Sheet','LCOE_IT_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','LCOE_total_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','LCOE_total_matrix', 'Range','A2');
        writematrix(cloudLCOE_total, cloudFile, 'Sheet','LCOE_total_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','GEP_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','GEP_matrix', 'Range','A2');
        writematrix(cloudGEP, cloudFile, 'Sheet','GEP_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','GreenHours_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','GreenHours_matrix', 'Range','A2');
        writematrix(cloudGreenHours, cloudFile, 'Sheet','GreenHours_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','GreenHourShare_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','GreenHourShare_matrix', 'Range','A2');
        writematrix(cloudGreenHourShare, cloudFile, 'Sheet','GreenHourShare_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','CurtRate_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','CurtRate_matrix', 'Range','A2');
        writematrix(cloudCurtRate, cloudFile, 'Sheet','CurtRate_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Cpv_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Cpv_matrix', 'Range','A2');
        writematrix(cloudCpv, cloudFile, 'Sheet','Cpv_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Cwt_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Cwt_matrix', 'Range','A2');
        writematrix(cloudCwt, cloudFile, 'Sheet','Cwt_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Cba_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Cba_matrix', 'Range','A2');
        writematrix(cloudCba, cloudFile, 'Sheet','Cba_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Cct_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Cct_matrix', 'Range','A2');
        writematrix(cloudCct, cloudFile, 'Sheet','Cct_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Curtail_total_MWh', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Curtail_total_MWh', 'Range','A2');
        writematrix(cloudCurtTot, cloudFile, 'Sheet','Curtail_total_MWh', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','ChillerElec_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','ChillerElec_matrix', 'Range','A2');
        writematrix(cloudChillerEle, cloudFile, 'Sheet','ChillerElec_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','TotalElec_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','TotalElec_matrix', 'Range','A2');
        writematrix(cloudTotalEle, cloudFile, 'Sheet','TotalElec_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Carbon_total_kgCO2e_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Carbon_total_kgCO2e_matrix', 'Range','A2');
        writematrix(cloudCarbonKg, cloudFile, 'Sheet','Carbon_total_kgCO2e_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','PUE_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','PUE_matrix', 'Range','A2');
        writematrix(cloudPUE, cloudFile, 'Sheet','PUE_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','CUE_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','CUE_matrix', 'Range','A2');
        writematrix(cloudCUE, cloudFile, 'Sheet','CUE_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Ppeak_shifted_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Ppeak_shifted_matrix', 'Range','A2');
        writematrix(cloudPpeakShift, cloudFile, 'Sheet','Ppeak_shifted_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Dur_BESS_shifted_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Dur_BESS_shifted_matrix', 'Range','A2');
        writematrix(cloudDurBESShift, cloudFile, 'Sheet','Dur_BESS_shifted_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Dur_CT_shifted_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Dur_CT_shifted_matrix', 'Range','A2');
        writematrix(cloudDurCTShift, cloudFile, 'Sheet','Dur_CT_shifted_matrix', 'Range','B2');

        % ===== 新增：CAPEX / OPEX 输出到 cloud.xlsx =====
        writecell(hdr, cloudFile, 'Sheet','CAPEX_total_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','CAPEX_total_matrix', 'Range','A2');
        writematrix(cloudCAPEX, cloudFile, 'Sheet','CAPEX_total_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','OPEX_total_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','OPEX_total_matrix', 'Range','A2');
        writematrix(cloudOPEX, cloudFile, 'Sheet','OPEX_total_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Export_annual_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Export_annual_matrix', 'Range','A2');
        writematrix(cloudExportAnnual, cloudFile, 'Sheet','Export_annual_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Export_revenue_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Export_revenue_matrix', 'Range','A2');
        writematrix(cloudExportRevenue, cloudFile, 'Sheet','Export_revenue_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','Export_ratio_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Export_ratio_matrix', 'Range','A2');
        writematrix(cloudExportRatio, cloudFile, 'Sheet','Export_ratio_matrix', 'Range','B2');

        writecell(hdr, cloudFile, 'Sheet','BESS_EFC_annual_matrix', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','BESS_EFC_annual_matrix', 'Range','A2');
        writematrix(cloudBessEFCAnnual, cloudFile, 'Sheet','BESS_EFC_annual_matrix', 'Range','B2');

        for dayIdx = 1:6
            efcDaySheet = sprintf('BESS_EFC_day%d_matrix', dayIdx);
            writecell(hdr, cloudFile, 'Sheet', efcDaySheet, 'Range','A1');
            writecell(cellstr(provSheets(:)), cloudFile, 'Sheet', efcDaySheet, 'Range','A2');
            writematrix(cloudBessEFCDay(:,:,dayIdx), cloudFile, 'Sheet', efcDaySheet, 'Range','B2');
        end

        writecell({'Prov','Free_GreenHours_actual(h)','Free_GreenHourShare_actual'}, cloudFile, 'Sheet','Free_GreenHours', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Free_GreenHours', 'Range','A2');
        writematrix([free_GreenHours, free_GreenHourShare], cloudFile, 'Sheet','Free_GreenHours', 'Range','B2');

        writecell({'Prov','Free_Carbon_total(kgCO2e/yr)','Free_PUE','Free_CUE(kgCO2e/kWh_IT)'}, cloudFile, 'Sheet','Free_Carbon_PUE_CUE', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Free_Carbon_PUE_CUE', 'Range','A2');
        writematrix([free_CarbonKg, free_PUE, free_CUE], cloudFile, 'Sheet','Free_Carbon_PUE_CUE', 'Range','B2');

        writecell({'Prov','Free_BESS_EFC_annual(cycle/yr)'}, cloudFile, 'Sheet','Free_BESS_EFC_annual', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Free_BESS_EFC_annual', 'Range','A2');
        writematrix(free_BessEFCAnnual, cloudFile, 'Sheet','Free_BESS_EFC_annual', 'Range','B2');

        freeDayHdr = [{'Prov'}, arrayfun(@(x) sprintf('Day%d', x), 1:6, 'uni', 0)];
        writecell(freeDayHdr, cloudFile, 'Sheet','Free_BESS_EFC_day', 'Range','A1');
        writecell(cellstr(provSheets(:)), cloudFile, 'Sheet','Free_BESS_EFC_day', 'Range','A2');
        writematrix(free_BessEFCDay, cloudFile, 'Sheet','Free_BESS_EFC_day', 'Range','B2');

        %% ---------- BestPoints（Knee / 80 / 100 / Free / FeasibleMax） ----------
        idx80  = find(abs(shares-0.8)<1e-12, 1, 'last');
        idx100 = find(abs(shares-1.0)<1e-12, 1, 'last');

        knee_zTarget = nan(numProv,1);
        knee_GEP = nan(numProv,1);
        knee_GreenHours = nan(numProv,1);
        knee_GreenHourShare = nan(numProv,1);
        knee_LCOE_IT = nan(numProv,1);
        knee_LCOE_total = nan(numProv,1);
        knee_CarbonKg = nan(numProv,1);
        knee_PUE = nan(numProv,1);
        knee_CUE = nan(numProv,1);
        knee_CurtRate = nan(numProv,1);

        ge80 = nan(numProv,1); gh80 = nan(numProv,1); ghs80 = nan(numProv,1); lc80_it = nan(numProv,1); lc80_total = nan(numProv,1); carbon80 = nan(numProv,1); pue80 = nan(numProv,1); cue80 = nan(numProv,1); cu80 = nan(numProv,1);
        ge100 = nan(numProv,1); gh100 = nan(numProv,1); ghs100 = nan(numProv,1); lc100_it = nan(numProv,1); lc100_total = nan(numProv,1); carbon100 = nan(numProv,1); pue100 = nan(numProv,1); cue100 = nan(numProv,1); cu100 = nan(numProv,1);

        for pp = 1:numProv
            lcoeline = cloudLCOE_IT(pp,:);
            validIdx = find(~isnan(lcoeline));
            if ~isempty(validIdx)
                [~, kpos] = min(lcoeline(validIdx));
                kpos = validIdx(kpos);
                knee_zTarget(pp)        = shares(kpos);
                knee_GEP(pp)            = cloudGEP(pp,kpos);
                knee_GreenHours(pp)     = cloudGreenHours(pp,kpos);
                knee_GreenHourShare(pp) = cloudGreenHourShare(pp,kpos);
                knee_LCOE_IT(pp)        = cloudLCOE_IT(pp,kpos);
                knee_LCOE_total(pp)     = cloudLCOE_total(pp,kpos);
                knee_CarbonKg(pp)       = cloudCarbonKg(pp,kpos);
                knee_PUE(pp)            = cloudPUE(pp,kpos);
                knee_CUE(pp)            = cloudCUE(pp,kpos);
                knee_CurtRate(pp)       = cloudCurtRate(pp,kpos);
            end

            if ~isempty(idx80) && ~isnan(cloudLCOE_IT(pp,idx80))
                ge80(pp)        = cloudGEP(pp,idx80);
                gh80(pp)        = cloudGreenHours(pp,idx80);
                ghs80(pp)       = cloudGreenHourShare(pp,idx80);
                lc80_it(pp)     = cloudLCOE_IT(pp,idx80);
                lc80_total(pp)  = cloudLCOE_total(pp,idx80);
                carbon80(pp)    = cloudCarbonKg(pp,idx80);
                pue80(pp)       = cloudPUE(pp,idx80);
                cue80(pp)       = cloudCUE(pp,idx80);
                cu80(pp)        = cloudCurtRate(pp,idx80);
            end

            if ~isempty(idx100) && ~isnan(cloudLCOE_IT(pp,idx100))
                ge100(pp)       = cloudGEP(pp,idx100);
                gh100(pp)       = cloudGreenHours(pp,idx100);
                ghs100(pp)      = cloudGreenHourShare(pp,idx100);
                lc100_it(pp)    = cloudLCOE_IT(pp,idx100);
                lc100_total(pp) = cloudLCOE_total(pp,idx100);
                carbon100(pp)   = cloudCarbonKg(pp,idx100);
                pue100(pp)      = cloudPUE(pp,idx100);
                cue100(pp)      = cloudCUE(pp,idx100);
                cu100(pp)       = cloudCurtRate(pp,idx100);
            end
        end

        bestHdr = { ...
            'Prov', ...
            'FeasibleMax_TargetGEP','FeasibleMax_ActualGEP', ...
            'Knee_zTarget','Knee_GEP','Knee_GreenHours(h)','Knee_GreenHourShare','Knee_LCOE_IT(¥/kWh)','Knee_LCOE_total(¥/kWh)','Knee_Carbon_total(kgCO2e/yr)','Knee_PUE','Knee_CUE(kgCO2e/kWh_IT)','Knee_CurtRate', ...
            'GEP_80','GreenHours_80(h)','GreenHourShare_80','LCOE_IT_80(¥/kWh)','LCOE_total_80(¥/kWh)','Carbon_80(kgCO2e/yr)','PUE_80','CUE_80(kgCO2e/kWh_IT)','CurtRate_80', ...
            'GEP_100','GreenHours_100(h)','GreenHourShare_100','LCOE_IT_100(¥/kWh)','LCOE_total_100(¥/kWh)','Carbon_100(kgCO2e/yr)','PUE_100','CUE_100(kgCO2e/kWh_IT)','CurtRate_100', ...
            'Free_GEP','Free_GreenHours(h)','Free_GreenHourShare','Free_LCOE_IT(¥/kWh)','Free_LCOE_total(¥/kWh)','Free_Carbon_total(kgCO2e/yr)','Free_PUE','Free_CUE(kgCO2e/kWh_IT)','Free_CurtRate', ...
            'Free_Export_annual(MWh)','Free_ExportRevenue(¥/yr)','Free_Export_ratio_to_RE_potential', ...
            'Free_Ppeak_shifted','Free_Dur_BESS_shifted(h)','Free_Dur_CT_shifted(h_th)', ...
            'Free_BESS_EFC_annual(cycle/yr)' ...
            };
        writecell(bestHdr, cloudFile, 'Sheet','BestPoints', 'Range','A1');
        bestRows = [ ...
            cellstr(provSheets(:)), ...
            num2cell(feasibleTargetMax), num2cell(feasibleActualMax), ...
            num2cell(knee_zTarget), num2cell(knee_GEP), num2cell(knee_GreenHours), num2cell(knee_GreenHourShare), num2cell(knee_LCOE_IT), num2cell(knee_LCOE_total), num2cell(knee_CarbonKg), num2cell(knee_PUE), num2cell(knee_CUE), num2cell(knee_CurtRate), ...
            num2cell(ge80), num2cell(gh80), num2cell(ghs80), num2cell(lc80_it), num2cell(lc80_total), num2cell(carbon80), num2cell(pue80), num2cell(cue80), num2cell(cu80), ...
            num2cell(ge100), num2cell(gh100), num2cell(ghs100), num2cell(lc100_it), num2cell(lc100_total), num2cell(carbon100), num2cell(pue100), num2cell(cue100), num2cell(cu100), ...
            num2cell(free_GEP), num2cell(free_GreenHours), num2cell(free_GreenHourShare), num2cell(free_LCOE_IT), num2cell(free_LCOE_total), num2cell(free_CarbonKg), num2cell(free_PUE), num2cell(free_CUE), num2cell(free_CurtRate), ...
            num2cell(free_ExportAnnual), num2cell(free_ExportRevenue), num2cell(free_ExportRatio), ...
            num2cell(free_PpeakShift), num2cell(free_DurBESShift), num2cell(free_DurCTShift), ...
            num2cell(free_BessEFCAnnual) ...
            ];
        writecell(bestRows, cloudFile, 'Sheet','BestPoints', 'Range','A2');

        fprintf('>>> 组合完成：%s', SCEN);
        if use_flex, fprintf(' alpha=%.0f%%', alpha*100); end
        fprintf('，政策=%s，负荷=%s，耗时 %.1fs。输出：%s / %s\n', POLICY_SCENARIO, LOAD_PROFILE, toc(t_case), outFile, cloudFile);
    end
end

end % load profile loop

fprintf('\n全部场景计算完毕。\n');

%% ==================== 局部函数：负荷曲线 ====================
function d = get_it_profile(profile_name, meanLoadMW)
% 返回 24x1 的 IT 负荷曲线，保持平均值 = meanLoadMW

switch lower(string(profile_name))
    case "flat"
        p = [ ...
            0.96 0.95 0.95 0.94 0.95 0.97 ...
            0.99 1.00 1.01 1.02 1.02 1.03 ...
            1.03 1.02 1.02 1.01 1.00 1.00 ...
            0.99 0.99 0.98 0.98 0.97 0.96 ...
        ];

    case "day_peak"
        p = [ ...
            0.72 0.70 0.68 0.67 0.69 0.74 ...
            0.84 0.98 1.12 1.24 1.32 1.36 ...
            1.38 1.36 1.32 1.26 1.18 1.08 ...
            0.98 0.90 0.84 0.80 0.76 0.74 ...
        ];

    case "night_bias"
        p = [ ...
            1.18 1.16 1.14 1.12 1.10 1.06 ...
            0.98 0.92 0.88 0.84 0.80 0.78 ...
            0.76 0.78 0.82 0.88 0.94 1.00 ...
            1.06 1.12 1.18 1.22 1.22 1.20 ...
        ];

    case "dual_peak"
        p = [ ...
            0.82 0.79 0.76 0.74 0.78 0.90 ...
            1.08 1.22 1.30 1.24 1.12 1.02 ...
            0.96 0.98 1.04 1.16 1.30 1.36 ...
            1.32 1.20 1.06 0.96 0.88 0.84 ...
        ];

    otherwise
        error('未知负荷曲线类型：%s', profile_name);
end

p = p(:);
p = p / mean(p);
d = meanLoadMW * p;
end

function code = get_load_profile_code(profile_name)
switch lower(string(profile_name))
    case "raw"
        code = 0;
    case "flat"
        code = 1;
    case "day_peak"
        code = 2;
    case "night_bias"
        code = 3;
    case "dual_peak"
        code = 4;
    otherwise
        error('未知负荷曲线类型：%s', profile_name);
end
end

function desc = get_load_profile_desc(profile_name)
switch lower(string(profile_name))
    case "raw"
        desc = "原始基准负荷";
    case "flat"
        desc = "持续高载型（训练 / HPC / 通用计算）";
    case "day_peak"
        desc = "日间-晚间峰值型（推理 / 用户请求驱动）";
    case "night_bias"
        desc = "夜间偏置型（后台批量计算，对照场景）";
    case "dual_peak"
        desc = "混合波动型（在线服务 + batch 混部）";
    otherwise
        error('未知负荷曲线类型：%s', profile_name);
end
end

%% ==================== 局部函数：COP(Twb) ====================
function [green_hours_annual, green_hour_share, green_flag, green_hours_contrib] = compute_green_hours(Pg_val, w, pg_zero_tol)
% 绿电小时数：若某典型日某小时 Pg <= pg_zero_tol，则该小时记为绿电小时
% green_hours_annual：按典型日权重折算到全年的小时数
% green_hour_share：green_hours_annual / 8760
% green_flag：24×NtypicalDay，0/1 标记
% green_hours_contrib：24×NtypicalDay，每个典型时段对全年绿电小时数的贡献（h/yr）

if nargin < 3 || isempty(pg_zero_tol)
    pg_zero_tol = 1e-6;
end

green_flag = double(Pg_val <= pg_zero_tol);
green_flag(~isfinite(green_flag)) = 0;
green_hours_contrib = green_flag .* repmat(reshape(w,1,[]), size(Pg_val,1), 1);
green_hours_annual = sum(green_hours_contrib(:));
green_hour_share = green_hours_annual / 8760;

% 数值清理
green_hours_annual = max(green_hours_annual, 0);
green_hour_share = min(max(green_hour_share, 0), 1);
end

function [efc_annual, efc_day] = compute_bess_efc(Pba_c_val, Pba_d_val, Cba_val, w)
% 储能等效完整循环次数：EFC = 0.5 × (充电量 + 放电量) / 容量
% efc_day：1×NtypicalDay，每个典型日的 cycle/day
% efc_annual：按典型日权重折算后的 cycle/yr

numDays = numel(w);
efc_day = zeros(1, numDays);
efc_annual = 0;

if isempty(Pba_c_val) || isempty(Pba_d_val) || Cba_val <= 1e-8
    return;
end

charge_day = max(sum(Pba_c_val, 1), 0);
discharge_day = max(sum(Pba_d_val, 1), 0);
efc_day = 0.5 * (charge_day + discharge_day) / Cba_val;
efc_day(abs(efc_day) < 1e-10) = 0;
efc_annual = efc_day * w(:);
end

function COP = cop_from_twb(Twet)
% 由湿球温度(°C)计算COP：沿用你之前代码中的分段经验函数
COP = zeros(size(Twet));

idx = (Twet <= -5);
COP(idx) = -0.001457*Twet(idx).^2 - 0.1068*Twet(idx) + 9.0156;

idx = (Twet > -5) & (Twet <= 7);
COP(idx) = -0.0079437*Twet(idx).^2 - 0.05831*Twet(idx) + 10.901;

idx = (Twet > 7) & (Twet <= 15);
COP(idx) = -0.0074756*Twet(idx).^2 + 0.1311*Twet(idx) + 5.1232;

idx = (Twet > 15);
COP(idx) = -0.0778*Twet(idx) + 6.4832;
end
