function varargout = microgridCheck(what)
%MICROGRIDCHECK  Every check this project carries, in one place.
%
%   microgridCheck                 structure and configuration, then a sweep of
%                                  every supervisor threshold.  Seconds.
%   microgridCheck('all')          the above, then a full simulation and a check
%                                  of what it produced.  Takes ~35 minutes.
%   microgridCheck('results')      judge the simulation already in the workspace
%                                  - use this after pressing Run on the model.
%   microgridCheck('thresholds')   the supervisor threshold sweep on its own.
%
%  Run the plain form after ANY change to the model or the parameters: every
%  check must still pass, and one that fails names exactly what the change
%  disturbed.
%
%  Replaces the former runRegression / checkRegressionRun / soc unit test.

if nargin < 1, what = 'structure'; end
switch lower(what)
    case {'structure','','check'}
        r = structureChecks();
    case 'all'
        r = structureChecks('sim',true);
    case 'results'
        r = resultChecks();
    case 'thresholds'
        r = thresholdSweep();
    otherwise
        error('microgridCheck:unknown', ...
              ['"%s" is not a mode.\n  use: microgridCheck, ' ...
               'microgridCheck(''all''), microgridCheck(''results'') ' ...
               'or microgridCheck(''thresholds'')'], what);
end
if nargout, varargout{1} = r; end
end

%% ======================================================================
%  structure and configuration
%% ======================================================================
function results = structureChecks(varargin)
%RUNREGRESSION  Re-verify the acceptance checks of every completed phase.
%
%   microgridCheck               structural + configuration checks (fast)
%   microgridCheck('all')     also runs a simulation and checks the result
%   microgridCheck('all')
%
% Run this after finishing any phase.  Every check from every earlier phase
% must still pass; a FAIL means the latest phase disturbed something that
% used to work.
%
% Structural checks take a few seconds.  The simulation check is separate
% because a 0.3 s run takes several minutes of wall clock.
%
% Returns a table with one row per check.

p = inputParser;
p.addParameter('sim',false,@(x)islogical(x)||isnumeric(x));
p.addParameter('stopTime',0.3);
p.addParameter('model','microgrid');
p.parse(varargin{:});
opt = p.Results;

mdl = opt.model;
R = struct('phase',{},'id',{},'name',{},'status',{},'detail',{});

fprintf('\n================================================================\n');
fprintf(' REGRESSION  -  %s   %s\n', mdl, datestr(now,'yyyy-mm-dd HH:MM:SS'));
fprintf('================================================================\n');

%% ---------------------------------------------------------------- setup
if bdIsLoaded(mdl), close_system(mdl,0); end     % force PreLoadFcn to fire
load_system(mdl);

TR = [mdl '/PCC + Grid/Three-Phase Transformer' char(10) ...
      'Inductance Matrix Type' char(10) '(Two Windings)'];
G  = [mdl '/PCC + Grid'];
GC = [G '/Grid Converter Control'];
D  = [mdl '/Drain'];
B  = [mdl '/Bidirectional DC//DC  Converter'];
BC = [B '/Battery Converter  Control'];

%% ========================= MODEL INTEGRITY ===========================

% ---- P0.1  model callback loads both parameter files
R = chk(R,0,'0.1','PreLoadFcn loads both parameter files', @() ...
    deal(contains(get_param(mdl,'PreLoadFcn'),'SolarPVMPPTBoostData') && ...
         contains(get_param(mdl,'PreLoadFcn'),'microgridParams'), ...
         sprintf('%d chars', numel(get_param(mdl,'PreLoadFcn')))));

% ---- P0.2  every required base-workspace variable exists after load
need = {'solarPanel','solarPlant','dcVoltage','environment','simulation', ...
        'boost','boostController','sensor','MPPT', ...
        'incrementalConductance','perturbationAndObservation','mg'};
R = chk(R,0,'0.2','Required workspace variables present after opening', @() ...
    varsPresent(need));

% ---- P0.3  model compiles
R = chk(R,0,'0.3','Model compiles (update diagram)', @() compiles(mdl));

% ---- P0.4  no unresolved Goto/From tags outside the commented panel
R = chk(R,0,'0.4','No unresolved From tags outside legacy panel', @() ...
    unresolvedTags(mdl));

% ---- P0.5  no unconnected signal ports
R = chk(R,0,'0.5','No unconnected signal ports', @() openPorts(mdl));

% ---- P0.6  Drain measurement filter still terminated
R = chk(R,0,'0.6','Drain/Transfer Fcn output is connected', @() ...
    portConnected([D '/Transfer Fcn'],'Outport',1));

% ---- P0.7  legacy AC measurement panel still out of the compile
R = chk(R,0,'0.7','Legacy Subsystem still commented out', @() ...
    deal(strcmp(get_param([mdl '/Subsystem'],'Commented'),'on'), ...
         get_param([mdl '/Subsystem'],'Commented')));

% ---- P0.8  MASTER SCOPE dead channels stay removed
R = chk(R,0,'0.8','MASTER SCOPE has 8 live channels, no [A] feeds', @() ...
    masterScopeOK(mdl));

% ---- P0.9  dashboard bindings
R = chk(R,0,'0.9','Knob1 gone; irradiance knob still bound', @() ...
    dashboardOK(mdl));

% ---- P0.10 powergui
R = chk(R,0,'0.10','powergui: Discrete, Ts = 5e-6, 50 Hz', @() ...
    deal(strcmp(get_param([mdl '/powergui'],'SimulationMode'),'Discrete') && ...
         strcmp(get_param([mdl '/powergui'],'SampleTime'),'5e-6') && ...
         strcmp(get_param([mdl '/powergui'],'frequency'),'50'), ...
         sprintf('%s / %s / %s Hz', get_param([mdl '/powergui'],'SimulationMode'), ...
                 get_param([mdl '/powergui'],'SampleTime'), ...
                 get_param([mdl '/powergui'],'frequency'))));

% ---- P0.11 solver
R = chk(R,0,'0.11','Solver: ode23tb, variable-step, MaxStep auto', @() ...
    solverOK(mdl));

%% ======================= PLANT AND TOPOLOGY ==========================

% ---- P1.1  parameter struct complete
needMg = {'Vbus_nom','Vdrain_on','Vdrain_off','Rdrain','Qbat_Ah','Lbat','Rbat_L', ...
          'Vlink_ref','Clink','Lgrid','Rgrid','Lgdc','Rgdc','Dgdc_nom','Id_max', ...
          'Kp_i_afe','Ki_i_afe','Kp_v_afe','Ki_v_afe','Kp_i_gdc','Ki_i_gdc', ...
          'Kp_i_bat','Ki_i_bat','Igrid_max','Ibat_max','Rdroop_grid','Vpv_ctrl_ref'};
R = chk(R,1,'1.1','microgridParams defines every required mg field', @() mgFields(needMg));

% ---- P1.2  active front end
R = chk(R,1,'1.2','Universal Bridge is IGBT/Diodes with its gate connected', @() ...
    afeBridgeOK(G));

% ---- P1.3  the zero-sequence fix
R = chk(R,1,'1.3','Transformer secondary is ungrounded (no zero-seq path)', @() ...
    deal(strcmp(get_param(TR,'Winding2Connection'),'Y'), ...
         sprintf('W1=%s W2=%s', get_param(TR,'Winding1Connection'), ...
                 get_param(TR,'Winding2Connection'))));

% ---- P1.4  the old unidirectional stage is gone
R = chk(R,1,'1.4','Old buck converter and fixed-duty constants removed', @() ...
    absent(G,{'Buck Converter','Duty term','0','1'}));

% ---- P1.5  new power stage present
R = chk(R,1,'1.5','New grid power stage blocks all present', @() ...
    present(G,{'VI meas','Line Reactor','Clink','S_hi','S_lo','Lgdc','Cbus', ...
               'I grid','Vlink meas','Vbus meas','Grid Converter Control'}));

% ---- P1.6  controller wired
R = chk(R,1,'1.6','Grid Converter Control: 5 inputs / 3 outputs, all connected', @() ...
    gcWired(G,GC));

% ---- P1.7  the droop duty actually reaches the converter
R = chk(R,1,'1.7','Droop duty output reaches the grid DC/DC', @() dutyPath(mdl,G,GC));

% ---- P1.8  drain rework
R = chk(R,1,'1.8','Drain: hysteresis relay, sized resistor, no PI on the gate', @() ...
    drainOK(D));

% ---- P1.9  battery and its converter
R = chk(R,1,'1.9','Battery resized and converter passives parameterised', @() ...
    batteryOK(mdl,B));

% ---- P1.10 interface initialisation
R = chk(R,1,'1.10','Simscape interface starts at the bus operating point', @() ...
    deal(strcmp(get_param([mdl '/Voltage-Current Simscape Interface'],'v0'),'mg.Vbus_nom'), ...
         get_param([mdl '/Voltage-Current Simscape Interface'],'v0')));

% ---- P1.11 reference filter initialisation
R = chk(R,1,'1.11','Vdc_ref filter initialised at 800 V (no 0->800 ramp)', @() ...
    deal(strcmp(get_param([mdl '/Subsystem1/LPF vq6'],'Initialize'),'on') && ...
         strcmp(get_param([mdl '/Subsystem1/LPF vq6'],'Vdc_Init'),'mg.Vbus_nom'), ...
         sprintf('Init=%s V0=%s', get_param([mdl '/Subsystem1/LPF vq6'],'Initialize'), ...
                 get_param([mdl '/Subsystem1/LPF vq6'],'Vdc_Init'))));

% ---- P1.12 droop controller operating-point init
% (the droop REFERENCE and current limits moved into the droop node;
%  what remains here is the grid converter's inner current loop)
R = chk(R,1,'1.12','Grid inner current PI initialised at the nominal duty', @() droopOK(mdl));

% ---- P1.13 no hard-coded literals left where a parameter belongs
R = chk(R,1,'1.13','Parameterised blocks reference mg.*, not literals', @() ...
    paramRefs(mdl,D,B,G));

%% ========================= CONVERTER LOOPS ===========================

% ---- P2.1  parameter struct covers the converter-loop additions
needMg2 = {'Kp_v_bat','Ki_v_bat','Dbat_nom','Dbat_trim','Dbat_min','Dbat_max', ...
           'Vbat_ff_min','Vbus_ff_min','Igrid_min'};
R = chk(R,2,'2.1','microgridParams defines the converter-loop fields', @() mgFields(needMg2));

% ---- P2.2  the sign-routed pulse gating is gone
R = chk(R,2,'2.2','Battery pulse gating by sign(Ibat_ref) removed', @() ...
    absent(BC,{'Sign','Compare To Constant','Compare To Constant1','Product','Product1'}));

% ---- P2.3  duty feed-forward built and wired
R = chk(R,2,'2.3','Battery duty feed-forward Vbat/Vbus present and wired', @() ...
    batFeedForward(BC));

% ---- P2.4  complementary switching, upper switch on pulse 1
R = chk(R,2,'2.4','Complementary switching: S1 on pulse 1, S2 on pulse 2', @() ...
    batPulseMap(BC));

% ---- P2.5  both PWM generators share one carrier convention
R = chk(R,2,'2.5','All PWM generators use the same -1..1 carrier', @() ...
    carrierConvention(mdl));

% ---- P2.6  anti-windup on both battery loops
% (PI 1, the outer voltage loop, is replaced by the droop node;
%  PI 2, the inner current loop, remains and is what this checks)
R = chk(R,2,'2.6','Battery current PI has integrator anti-windup and mg gains', @() ...
    batPIloops(BC));

% ---- P2.7  the grid may now export
R = chk(R,2,'2.7','Grid current reference may go negative (export)', @() ...
    deal(strcmp(get_param([mdl '/DROOP CONTROLLER/Grid Droop'],'Imin'),'mg.Igrid_min'), ...
         sprintf('limits %s .. %s', ...
            get_param([mdl '/DROOP CONTROLLER/Grid Droop'],'Imin'), ...
            get_param([mdl '/DROOP CONTROLLER/Grid Droop'],'Imax'))));

% ---- P2.8  PV curtailment target decoupled from the bus nominal
R = chk(R,2,'2.8','PV voltage-control target is its own reference (850 V)', @() ...
    pvRef(mdl));

%% =========================== DROOP LAYER =============================

% ---- P3.1  the droop library exists and holds the reusable blocks
R = chk(R,3,'3.1','microgridLib library provides the reusable droop blocks', @() droopLib());

% ---- P3.2  parameter struct covers the droop design
needMg3 = {'Vdroop_band','Rdroop_bat','DB_bat','Rdroop_grid','DB_grid', ...
           'V0_bat','V0_grid','Tf_droop','Rdroop_pv','Cbus','wc_droop','Kdroop_total'};
R = chk(R,3,'3.2','microgridParams defines the droop-layer fields', @() mgFields(needMg3));

% ---- P3.3  battery droop node
R = chk(R,3,'3.3','Battery droop node linked to the library and parameterised', @() ...
    droopNode([BC '/Battery Droop'],'mg.Rdroop_bat','mg.DB_bat','-mg.Ibat_max','mg.Ibat_max'));

% ---- P3.4  grid droop node
R = chk(R,3,'3.4','Grid droop node linked to the library and parameterised', @() ...
    droopNode([mdl '/DROOP CONTROLLER/Grid Droop'],'mg.Rdroop_grid','mg.DB_grid','mg.Igrid_min','mg.Igrid_max'));

% ---- P3.5  the outer voltage PIs they replace are gone
R = chk(R,3,'3.5','Outer voltage PIs replaced by droop nodes', @() ...
    bothAbsent(BC,{'PI 1','Sum3'}, [mdl '/DROOP CONTROLLER'],{'PID Controller1','R_droop','Subtract','Subtract2'}));

% ---- P3.6  set-points are signals, so the supervisor can shift them
R = chk(R,3,'3.6','Droop set-points are signal inputs, not fixed constants', @() ...
    setpointsAreSignals(BC,[mdl '/DROOP CONTROLLER']));

% ---- P3.7  bus capacitance sized for the droop bandwidth
R = chk(R,3,'3.7','DC bus capacitance sized for the droop loop', @() busCap(mdl));


%% ============================ SUPERVISOR =============================

SUP = [mdl '/Supervisor'];

% ---- P4.1  parameter struct covers the supervisor
needMg4 = {'t_island','k_soc','V0bat_min','V0bat_max','SOC_target','SOC_max', ...
           'SOC_min','SOC_hyst','Vbus_emerg','Vbus_emerg_off', ...
           'Vpv_ctrl_on','Vpv_ctrl_off','Vpv_ctrl_ref','Pbat_rated','BatChemistry'};
R = chk(R,4,'4.1','microgridParams defines the supervisor fields', @() mgFields(needMg4));

% ---- P4.2  the supervisor exists and publishes the full signal set
R = chk(R,4,'4.2','Supervisor publishes all nine policy signals, globally', @() ...
    supervisorOK(SUP));

% ---- P4.3  bus filter breaks the mode/limit algebraic loop
R = chk(R,4,'4.3','Supervisor filters the bus through a state (no algebraic loop)', @() ...
    busFilterOK(SUP));

% ---- P4.4  droop set-points come from the supervisor, not the old constant
R = chk(R,4,'4.4','Droop set-points sourced from V0bat / V0grid', @() ...
    setpointSource(mdl));

% ---- P4.5/4.6  policy limiters sit on the droop node OUTPUTS
R = chk(R,4,'4.5','Battery droop output passes through the Ibat policy limiter', @() ...
    limiterOK(BC,'Battery Droop','Ibat limit','Ibat_hi','Ibat_lo'));
R = chk(R,4,'4.6','Grid droop output passes through the Igrid policy limiter', @() ...
    limiterOK([mdl '/DROOP CONTROLLER'],'Grid Droop','Igrid limit','Igrid_hi','Igrid_lo'));

% ---- P4.7  every threshold has hysteresis and is expressed in mg
R = chk(R,4,'4.7','All supervisor thresholds are hysteretic and parameterised', @() ...
    relaysOK(SUP));

% ---- P4.8  the PV handover is automatic and cannot be overridden by hand
R = chk(R,4,'4.8','PV mode selector driven by pvMode; manual slider removed', @() ...
    pvModeOK(mdl));

% ---- P4.9  islanding is a plant event, not a control-level pretence
R = chk(R,4,'4.9','Grid breaker in the AC path, closed, opens at mg.t_island', @() ...
    breakerOK(mdl));

% ---- P4.10 plant and control agree on when the island starts
R = chk(R,4,'4.10','Breaker and island flag share the same mg.t_island', @() ...
    islandTimeOK(mdl,SUP));

% ---- P4.12 the grid converter is gated, not merely un-commanded
R = chk(R,4,'4.12','Grid converter gates blocked while islanded', @() ...
    gateBlockOK(mdl));

% ---- P4.13 the battery can actually deliver what its limit promises
R = chk(R,4,'4.13','Battery pack rated for the islanded park', @() batterySized(mdl));

% ---- P4.11 nothing in the supervisor is a magic number
R = chk(R,4,'4.11','Supervisor carries no hard-coded numeric thresholds', @() ...
    symbolicSupervisor(SUP));


%% ============= ISLANDING, SHEDDING AND CHARGING SESSIONS =============

% ---- P5.1  parameter struct covers islanding, shedding and sessions
needMg5 = {'t_reconnect','t_resync','Vshed','Vshed_hyst','Vshed_rst', ...
           'Rload_open','Pload_peak','Tend','evSessions','evLoad', ...
           'Tf_reshed','Poverload_bay'};
R = chk(R,5,'5.1','microgridParams defines the islanding and shedding fields', @() mgFields(needMg5));

% ---- P5.2  the droop node's measurement filter has an initial condition
R = chk(R,5,'5.2','Droop measurement filter is an initialised lag, not a 0-IC TF', @() ...
    droopFilterInit(mdl));

% ---- P5.3  islanding is a window, not a one-way step
R = chk(R,5,'5.3','Island is a window: opens at t_island, closes at t_reconnect', @() ...
    islandWindowOK(mdl));

% ---- P5.4  the converter comes back later than the breaker
R = chk(R,5,'5.4','gridEnable released one resync window after the reclose', @() ...
    gridEnableOK(mdl));

% ---- P5.5  the plant performs the whole cycle
R = chk(R,5,'5.5','Breaker opens and recloses on the same mg parameters', @() ...
    breakerCycleOK(mdl));

% ---- P5.6  no loop may come back from the island still wound up
R = chk(R,5,'5.6','All three AFE loops held in reset while gated off', @() ...
    afeResetOK(mdl));

% ---- P5.7  shedding thresholds sit below the band and restore inside it
R = chk(R,5,'5.7','Load shedding: 4 stages, hysteretic, below the droop band', @() ...
    shedRelaysOK(mdl));

% ---- P5.8  and each stage actually reaches its bay
R = chk(R,5,'5.8','Every bay can be shed to an open circuit', @() shedSwitchesOK(mdl));

% ---- P5.11 shedding restores on a sustained recovery, not an instant one
R = chk(R,5,'5.11','Shedding sheds on the fast bus, restores on the slow one', @() ...
    shedRestoreLagOK(mdl));

% ---- P5.12 the solver must survive an ideal switch
R = chk(R,5,'5.12','Zero-crossing detection is adaptive', @() ...
    deal(strcmp(get_param(getActiveConfigSet(mdl),'ZeroCrossAlgorithm'),'Adaptive'), ...
         get_param(getActiveConfigSet(mdl),'ZeroCrossAlgorithm')));

% ---- P5.9  the load profiles are generated, not typed
R = chk(R,5,'5.9','Load profiles come from mg.evLoad, not literal matrices', @() ...
    evProfilesWired(mdl));

% ---- P5.10 and they are well formed
R = chk(R,5,'5.10','EV session profiles well formed over the whole horizon', @() evProfilesOK());

%% ---------------------------------------------------------------- report
results = struct2table(R);
printReport(R);

%% ---------------------------------------------------------------- sim
% The supervisor's thresholds are swept directly - it runs in seconds and
% covers ground no plant run can reach (0-100 % of SOC, the whole bus range).
% See the threshold sweep below for why it replaced an accelerated-capacity run.
try
    thresholdSweep();
catch thrErr
    fprintf('\n  threshold sweep could not run: %s\n', thrErr.message);
end

if opt.sim
    fprintf('\nRunning simulation to t = %g s (this takes a while)...\n', opt.stopTime);
    old = get_param(mdl,'StopTime');
    set_param(mdl,'StopTime',num2str(opt.stopTime));
    t0 = tic;
    sim(mdl);
    set_param(mdl,'StopTime',old);
    fprintf('simulation finished in %.0f s wall clock\n', toc(t0));
    resultChecks;
end
end

%% ======================================================================
%  helpers
%% ======================================================================
function R = chk(R,phase,id,name,fcn)
try
    [ok,detail] = fcn();
catch ME
    ok = false; detail = ['ERROR: ' strrep(ME.message,char(10),' ')];
end
if ~ischar(detail) && ~isstring(detail), detail = mat2str(detail); end
n = numel(R)+1;
R(n).phase  = phase;
R(n).id     = id;
R(n).name   = name;
R(n).status = ternary(ok,"PASS","FAIL");
R(n).detail = char(detail);
end

function out = ternary(c,a,b), if c, out=a; else, out=b; end, end

function [ok,detail] = varsPresent(need)
missing = need(~cellfun(@(v) evalin('base',sprintf('exist(''%s'',''var'')',v))>0, need));
ok = isempty(missing);
detail = ternary(ok, sprintf('%d/%d present',numel(need),numel(need)), ...
                     ['missing: ' strjoin(missing,', ')]);
end

function [ok,detail] = compiles(mdl)
try
    set_param(mdl,'SimulationCommand','update');
    ok = true; detail = 'update OK';
catch ME
    ok = false; detail = strrep(ME.message,char(10),' ');
end
end

function [ok,detail] = unresolvedTags(mdl)
% Only tags the model itself owns are checked.  Two sources of noise are
% excluded:
%   * Specialized Power Systems library blocks (Current/Voltage Measurement
%     and friends) create their own internal Goto/From pairs with generated
%     names like T35_3272_1791421670588.  The Goto half lives inside the
%     linked library block, so the Goto list is built with FollowLinks on.
%   * powergui builds an 'EquivalentModel' subsystem at compile time and
%     fills it with more of the same.  That is generated machinery, not
%     authored content, so the whole powergui subtree is skipped.
ga = [find_system(mdl,'LookUnderMasks','all','FollowLinks','off','BlockType','Goto'); ...
      find_system(mdl,'LookUnderMasks','all','FollowLinks','on', 'BlockType','Goto')];
gt = unique(cellfun(@(x) get_param(x,'GotoTag'), ga,'uni',0));
fa = find_system(mdl,'LookUnderMasks','all','FollowLinks','off','BlockType','From');
legacy   = [mdl '/Subsystem/'];
generated = [mdl '/powergui/'];
bad = {}; nchecked = 0;
for k = 1:numel(fa)
    if strncmp(fa{k},legacy,numel(legacy)), continue; end
    if strncmp(fa{k},generated,numel(generated)), continue; end
    if underLinkOrVariant(fa{k},mdl), continue; end
    nchecked = nchecked + 1;
    t = get_param(fa{k},'GotoTag');
    if ~any(strcmp(t,gt)), bad{end+1} = t; end %#ok<AGROW>
end
ok = isempty(bad);
detail = ternary(ok, sprintf('0 unresolved of %d model-owned From blocks', nchecked), ...
                     ['unresolved: ' strjoin(unique(bad),', ')]);
end

function [ok,detail] = openPorts(mdl)
b = find_system(mdl,'LookUnderMasks','all','FollowLinks','off','Type','Block');
bad = {};
for k = 1:numel(b)
    if ~isempty(get_param(b{k},'ReferenceBlock')), continue; end
    if underLinkOrVariant(b{k},mdl), continue; end
    ph = get_param(b{k},'PortHandles');
    for f = {'Inport','Outport','Enable','Trigger'}
        if ~isfield(ph,f{1}), continue; end
        pp = ph.(f{1});
        for j = 1:numel(pp)
            if get_param(pp(j),'Line') <= 0
                bad{end+1} = sprintf('%s.%s%d', strrep(strrep(b{k},[mdl '/'],''),char(10),' '), f{1}, j); %#ok<AGROW>
            end
        end
    end
end
ok = isempty(bad);
detail = ternary(ok,'0 open ports',strjoin(bad,'; '));
end

function tf = underLinkOrVariant(blk,mdl)
tf = false; q = blk;
while true
    i = strfind(q,'/');
    if isempty(i), return; end
    q = q(1:i(end)-1);
    if strcmp(q,mdl), return; end
    try
        if ~isempty(get_param(q,'ReferenceBlock')), tf = true; return; end
        if strcmp(get_param(q,'Variant'),'on'),     tf = true; return; end
        if ~strcmp(get_param(q,'Commented'),'off'), tf = true; return; end
    catch
        return
    end
end
end

function [ok,detail] = portConnected(blk,type,idx)
ph = get_param(blk,'PortHandles');
l  = get_param(ph.(type)(idx),'Line');
ok = l > 0;
if ok
    d = get_param(l,'DstPortHandle');
    ok = ~isempty(d) && any(d > 0);
end
detail = ternary(ok,'connected','no destination');
end

function [ok,detail] = masterScopeOK(mdl)
ms = [mdl '/MASTER SCOPE'];
n  = numel(find_system(ms,'SearchDepth',1,'BlockType','Inport'));
f  = find_system(mdl,'SearchDepth',1,'BlockType','From');
tags = cellfun(@(x) get_param(x,'GotoTag'), f, 'uni',0);
ok = (n == 8) && ~any(strcmp(tags,'A'));
detail = sprintf('%d inports, [A] feeds: %d', n, sum(strcmp(tags,'A')));
end

function [ok,detail] = dashboardOK(mdl)
% The manual selector 'Slider Switch' was removed: it was the MANUAL PV mode selector, bound
% to a constant that no longer exists now that the handover is automatic.  A
% hand switch on an automatic protection is a way to defeat it, so the block
% was deleted rather than rebound.  Only the irradiance knob is expected here.
gone = isempty(find_system(mdl,'LookUnderMasks','all','FindAll','on','Type','Block','Name','Knob1')) && ...
       isempty(find_system(mdl,'LookUnderMasks','all','FindAll','on','Type','Block','Name','Slider Switch'));
good = 0; tot = 0;
for nm = {'Knob2'}
    h = find_system(mdl,'LookUnderMasks','all','FindAll','on','Type','Block','Name',nm{1});
    if isempty(h), continue; end
    tot = tot + 1;
    try
        s = get_param(h(1),'Binding').BlockPath.getBlock(1);
        get_param(s,'Name');   % throws if the target no longer exists
        good = good + 1;
    catch
    end
end
ok = gone && good == tot && tot == 1;
detail = sprintf('Knob1+slider removed=%d, valid bindings=%d/%d', gone, good, tot);
end

function [ok,detail] = solverOK(mdl)
cs = getActiveConfigSet(mdl);
ok = strcmp(get_param(cs,'Solver'),'ode23tb') && ...
     strcmp(get_param(cs,'SolverType'),'Variable-step') && ...
     strcmp(get_param(cs,'MaxStep'),'auto');
detail = sprintf('%s / %s / MaxStep=%s', get_param(cs,'Solver'), ...
                 get_param(cs,'SolverType'), get_param(cs,'MaxStep'));
end

function [ok,detail] = mgFields(need)
mg = evalin('base','mg');
missing = need(~isfield(mg,need));
ok = isempty(missing);
detail = ternary(ok, sprintf('%d fields checked', numel(need)), ...
                     ['missing: ' strjoin(missing,', ')]);
end

function [ok,detail] = afeBridgeOK(G)
ub = [G '/Universal Bridge'];
dev = get_param(ub,'Device');
ph  = get_param(ub,'PortHandles');
gated = ~isempty(ph.Inport) && get_param(ph.Inport(1),'Line') > 0;
ok = strcmp(dev,'IGBT / Diodes') && gated;
detail = sprintf('device=%s, gate connected=%d', dev, gated);
end

function [ok,detail] = absent(sys,names)
found = {};
for k = 1:numel(names)
    if ~isempty(find_system(sys,'SearchDepth',1,'LookUnderMasks','all','Name',names{k}))
        found{end+1} = names{k}; %#ok<AGROW>
    end
end
ok = isempty(found);
detail = ternary(ok,'all removed',['still present: ' strjoin(found,', ')]);
end

function [ok,detail] = present(sys,names)
missing = {};
for k = 1:numel(names)
    if isempty(find_system(sys,'SearchDepth',1,'LookUnderMasks','all','Name',names{k}))
        missing{end+1} = names{k}; %#ok<AGROW>
    end
end
ok = isempty(missing);
detail = ternary(ok, sprintf('%d/%d present',numel(names),numel(names)), ...
                     ['missing: ' strjoin(missing,', ')]);
end

function [ok,detail] = gcWired(G,GC)
ph = get_param(GC,'PortHandles');
nIn = numel(ph.Inport); nOut = numel(ph.Outport);
open = 0;
for j = 1:nIn,  if get_param(ph.Inport(j),'Line')  <= 0, open = open+1; end, end
for j = 1:nOut, if get_param(ph.Outport(j),'Line') <= 0, open = open+1; end, end
ok = nIn == 5 && nOut == 3 && open == 0;
detail = sprintf('%d in / %d out, %d unconnected', nIn, nOut, open);
end

function [ok,detail] = dutyPath(mdl,G,GC)
% top level: droop duty -> PCC + Grid inport
dph = get_param([mdl '/DROOP CONTROLLER'],'PortHandles');
l1  = get_param(dph.Outport(1),'Line');
ok1 = l1 > 0 && any(get_param(l1,'DstPortHandle') > 0);
% inside: PCC inport -> Grid Converter Control (not a terminator)
ip  = [G '/ Dury Cycle '];
ph  = get_param(ip,'PortHandles');
l2  = get_param(ph.Outport(1),'Line');
ok2 = false; dst = '';
if l2 > 0
    d = get_param(l2,'DstPortHandle');
    d = d(d>0);
    if ~isempty(d)
        dst = get_param(get_param(d(1),'Parent'),'Name');
        ok2 = strcmp(dst,'Grid Converter Control');
    end
end
% and inside the controller it must reach the duty saturation
ok3 = ~isempty(find_system(GC,'SearchDepth',1,'Name','Sat D'));
ok = ok1 && ok2 && ok3;
detail = sprintf('droop->PCC=%d, PCC inport->%s, Sat D=%d', ok1, dst, ok3);
end

function [ok,detail] = drainOK(D)
hasRelay = ~isempty(find_system(D,'SearchDepth',1,'BlockType','Relay'));
noPI     = isempty(find_system(D,'SearchDepth',1,'LookUnderMasks','all','Name','PID Controller'));
r  = get_param([D '/Series RLC Branch'],'Resistance');
on = ''; off = '';
if hasRelay
    on  = get_param([D '/Drain hysteresis'],'OnSwitchValue');
    off = get_param([D '/Drain hysteresis'],'OffSwitchValue');
end
ok = hasRelay && noPI && strcmp(r,'mg.Rdrain') && ...
     strcmp(on,'mg.Vdrain_on') && strcmp(off,'mg.Vdrain_off');
detail = sprintf('relay=%d PIremoved=%d R=%s on=%s off=%s', hasRelay, noPI, r, on, off);
end

function [ok,detail] = batteryOK(mdl,B)
bp = [mdl '/Battery/Battery'];
q  = get_param(bp,'NomQ');
v  = get_param(bp,'NomV');
L  = get_param([B '/L'],'Inductance');
RL = get_param([B '/L'],'Resistance');
ok = strcmp(q,'mg.Qbat_Ah') && strcmp(v,'mg.Vbat_nom') && ...
     strcmp(L,'mg.Lbat') && strcmp(RL,'mg.Rbat_L');
detail = sprintf('NomQ=%s NomV=%s L=%s R=%s', q, v, L, RL);
end

function [ok,detail] = droopOK(mdl)
d  = [mdl '/DROOP CONTROLLER/'];
ic = get_param([d 'PID Controller'],'InitialConditionForIntegrator');
kp = get_param([d 'PID Controller'],'P');
ok = strcmp(ic,'mg.Dgdc_nom') && strcmp(kp,'mg.Kp_i_gdc');
detail = sprintf('IC=%s Kp=%s', ic, kp);
end

function [ok,detail] = paramRefs(mdl,D,B,G)
checks = { ...
    [D '/Ideal Switch'],            'Ron',        'mg.Rdrain_on'; ...
    [B '/Battery Converter  Control/PI 2/Gain1'], 'Gain', 'mg.Kp_i_bat'; ...
    [B '/Battery Converter  Control/PI 2/Gain2'], 'Gain', 'mg.Ki_i_bat'; ...
    [G '/Line Reactor'],            'Inductance', 'mg.Lgrid'; ...
    [G '/Clink'],                   'Capacitance','mg.Clink'; ...
    [G '/Lgdc'],                    'Inductance', 'mg.Lgdc'; ...
    };
bad = {};
for k = 1:size(checks,1)
    try
        v = get_param(checks{k,1},checks{k,2});
        if ~strcmp(v,checks{k,3})
            bad{end+1} = sprintf('%s.%s=%s', ...
                strrep(strrep(checks{k,1},[mdl '/'],''),char(10),' '), checks{k,2}, v); %#ok<AGROW>
        end
    catch
        bad{end+1} = [checks{k,1} ' missing']; %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok, sprintf('%d parameters verified',size(checks,1)), strjoin(bad,'; '));
end

function n = groupName(g)
%GROUPNAME  What each group of checks covers.  The leading digit of a check id
%  is just its group number - it is a label, not a sequence you have to follow.
switch g
    case 0, n = 'MODEL INTEGRITY';
    case 1, n = 'PLANT AND TOPOLOGY';
    case 2, n = 'CONVERTER LOOPS';
    case 3, n = 'DROOP LAYER';
    case 4, n = 'SUPERVISOR';
    case 5, n = 'ISLANDING, SHEDDING, SESSIONS';
    otherwise, n = sprintf('GROUP %d', g);
end
end

function printReport(R)
fprintf('\n');
ph = -1;
for k = 1:numel(R)
    if R(k).phase ~= ph
        ph = R(k).phase;
        fprintf('\n--- %-28s -----------------------------\n', groupName(ph));
    end
    fprintf('  [%s]  %-6s %-58s %s\n', R(k).status, R(k).id, R(k).name, R(k).detail);
end
nf = sum(strcmp([R.status],"FAIL"));
fprintf('\n================================================================\n');
if nf == 0
    fprintf(' ALL %d STRUCTURAL CHECKS PASSED\n', numel(R));
else
    fprintf(' %d of %d CHECKS FAILED\n', nf, numel(R));
end
fprintf('================================================================\n\n');
end

function [ok,detail] = batFeedForward(BC)
need = {'From Vbat','Sat Vbat','Sat Vbus','D ff','Sum D','Sat D'};
[ok1,d1] = present(BC,need);
ok2 = false; d2 = '';
if ok1
    v1 = get_param([BC '/Sat Vbat'],'LowerLimit');
    v2 = get_param([BC '/Sat Vbus'],'LowerLimit');
    v3 = get_param([BC '/Sat D'],'LowerLimit');
    v4 = get_param([BC '/Sat D'],'UpperLimit');
    ok2 = strcmp(v1,'mg.Vbat_ff_min') && strcmp(v2,'mg.Vbus_ff_min') && ...
          strcmp(v3,'mg.Dbat_min') && strcmp(v4,'mg.Dbat_max');
    d2 = sprintf('guards %s / %s, duty %s..%s', v1, v2, v3, v4);
end
ok = ok1 && ok2;
detail = ternary(ok, d2, [d1 ' ' d2]);
end

function [ok,detail] = batPulseMap(BC)
ph = get_param([BC '/Demux'],'PortHandles');
tgt = cell(1,2);
for j = 1:2
    l = get_param(ph.Outport(j),'Line');
    names = {};
    if l > 0
        d = get_param(l,'DstPortHandle'); d = d(d>0);
        for q = 1:numel(d)
            names{end+1} = get_param(get_param(d(q),'Parent'),'Name'); %#ok<AGROW>
        end
    end
    tgt{j} = names;
end
ok = any(strcmp(tgt{1},'S1')) && any(strcmp(tgt{2},'S2'));
detail = sprintf('pulse1 -> %s | pulse2 -> %s', strjoin(tgt{1},','), strjoin(tgt{2},','));
end

function [ok,detail] = carrierConvention(mdl)
% every PWM Generator in the model must use the -1..1 triangular carrier
pw = find_system(mdl,'LookUnderMasks','all','FollowLinks','off','MaskType','PWM Generator');
bad = {}; n = 0;
for k = 1:numel(pw)
    tri = find_system(pw{k},'LookUnderMasks','all','FollowLinks','on','Regexp','on','Name','Triangle');
    for j = 1:numel(tri)
        try
            y = get_param(tri{j},'rep_seq_y');
            n = n + 1;
            if ~contains(y,'-1')
                bad{end+1} = sprintf('%s: %s', get_param(pw{k},'Name'), y); %#ok<AGROW>
            end
        catch
        end
    end
end
ok = isempty(bad) && n > 0;
detail = ternary(ok, sprintf('%d carriers, all -1..1', n), strjoin(bad,'; '));
end

function [ok,detail] = batPIloops(BC)
bad = {};
spec = { 'PI 2','mg.Kp_i_bat','mg.Ki_i_bat','mg.Dbat_trim','-mg.Dbat_trim' };
for k = 1:size(spec,1)
    p = [BC '/' spec{k,1}];
    if ~strcmp(get_param([p '/Gain1'],'Gain'),spec{k,2}), bad{end+1} = [spec{k,1} ' Kp']; end %#ok<AGROW>
    if ~strcmp(get_param([p '/Gain2'],'Gain'),spec{k,3}), bad{end+1} = [spec{k,1} ' Ki']; end %#ok<AGROW>
    if ~strcmp(get_param([p '/Saturation'],'UpperLimit'),spec{k,4}), bad{end+1} = [spec{k,1} ' sat']; end %#ok<AGROW>
    if ~strcmp(get_param([p '/Integrator'],'LimitOutput'),'on'), bad{end+1} = [spec{k,1} ' anti-windup']; end %#ok<AGROW>
    if ~strcmp(get_param([p '/Integrator'],'UpperSaturationLimit'),spec{k,4}), bad{end+1} = [spec{k,1} ' int lim']; end %#ok<AGROW>
end
ok = isempty(bad);
detail = ternary(ok,'current loop parameterised with anti-windup',strjoin(bad,', '));
end

function [ok,detail] = pvRef(mdl)
cv = [mdl '/PV + Boost/PV Control/Constant Voltage/Constant'];
c  = get_param(cv,'Value');
haveConst = ~isempty(find_system(mdl,'SearchDepth',1,'BlockType','Constant','Name','Vpv_ctrl_ref'));
src = '';
if haveConst
    ph = get_param([mdl '/PV + Boost'],'PortHandles');
    l  = get_param(ph.Inport(1),'Line');
    if l > 0, src = get_param(get_param(l,'SrcBlockHandle'),'Name'); end
end
ok = strcmp(c,'mg.Vpv_ctrl_ref') && strcmp(src,'Vpv_ctrl_ref');
detail = sprintf('guard=%s, PV Vref fed by %s', c, ternary(isempty(src),'(none)',src));
end

function [ok,detail] = droopLib()
lib = 'microgridLib';
if ~bdIsLoaded(lib)
    try, load_system(lib); catch, ok=false; detail='library will not load'; return; end
end
have = {};
for n = {'DC Droop Node','Droop Reference'}
    if ~isempty(find_system(lib,'SearchDepth',1,'Name',n{1})), have{end+1} = n{1}; end %#ok<AGROW>
end
ok = numel(have) == 2;
detail = ternary(ok,'DC Droop Node + Droop Reference',['only: ' strjoin(have,', ')]);
end

function [ok,detail] = droopNode(blk,R_,DB_,Imin_,Imax_)
link = get_param(blk,'LinkStatus');
ref  = get_param(blk,'ReferenceBlock');
okLink = strcmp(link,'resolved') && contains(ref,'DC Droop Node');
vals = {get_param(blk,'Rdroop'), get_param(blk,'DB'), get_param(blk,'Imin'), get_param(blk,'Imax')};
want = {R_, DB_, Imin_, Imax_};
okVal = all(cellfun(@(a,b) strcmp(a,b), vals, want));
okTf  = strcmp(get_param(blk,'Tf'),'mg.Tf_droop');
ok = okLink && okVal && okTf;
detail = sprintf('link=%s R=%s DB=%s lim=%s..%s Tf=%s', link, vals{1}, vals{2}, vals{3}, vals{4}, get_param(blk,'Tf'));
end

function [ok,detail] = bothAbsent(s1,n1,s2,n2)
[o1,d1] = absent(s1,n1);
[o2,d2] = absent(s2,n2);
ok = o1 && o2;
detail = ternary(ok,'battery and grid outer PIs removed',[d1 ' | ' d2]);
end

function [ok,detail] = setpointsAreSignals(BC,DC)
% the V0 input of each droop node must be driven by a line, so a supervisor
% can move the set-point at run time
bad = {};
for b = {[BC '/Battery Droop'], [DC '/Grid Droop']}
    ph = get_param(b{1},'PortHandles');
    if numel(ph.Inport) < 2 || get_param(ph.Inport(1),'Line') <= 0
        bad{end+1} = get_param(b{1},'Name'); %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok,'both V0 inputs driven by signals',['unconnected V0: ' strjoin(bad,', ')]);
end

function [ok,detail] = busCap(mdl)
c = get_param([mdl '/PV + Boost/Boost Converter/DC Bus Capacitor'],'c');
mg = evalin('base','mg');
wc = mg.Kdroop_total/mg.Cbus;                 % droop crossover, rad/s
sep = mg.wc_i_bat/wc;                          % separation from the inner loop
ok = strcmp(c,'mg.Cbus') && sep >= 5;
detail = sprintf('C=%s (%.0f mF), droop %.0f rad/s vs inner %.0f rad/s, separation %.1fx', ...
                 c, mg.Cbus*1e3, wc, mg.wc_i_bat, sep);
end

%% ---------------------------------------------------------------- supervisor

function [ok,detail] = supervisorOK(SUP)
%SUPERVISOROK  The supervisor exists and publishes every policy signal.
if getSimulinkBlockHandle(SUP) <= 0
    ok = false; detail = 'no Supervisor subsystem'; return
end
want = {'V0bat','Ibat_hi','Ibat_lo','V0grid','Igrid_hi','Igrid_lo', ...
        'pvMode','island','gridEnable'};
g = find_system(SUP,'SearchDepth',1,'LookUnderMasks','all','BlockType','Goto');
have = cellfun(@(b) get_param(b,'GotoTag'), g, 'uni', 0);
vis  = cellfun(@(b) get_param(b,'TagVisibility'), g, 'uni', 0);
missing = want(~ismember(want,have));
notGlobal = have(~strcmp(vis,'global'));
ok = isempty(missing) && isempty(notGlobal);
detail = ternary(ok, sprintf('%d tags, all global', numel(want)), ...
         sprintf('missing: %s | not global: %s', strjoin(missing,','), strjoin(notGlobal,',')));
end

function [ok,detail] = busFilterOK(SUP)
%BUSFILTEROK  The bus measurement passes through an integrator before any relay.
%  This is what stops Simulink seeing Vbus -> mode -> duty -> plant -> Vbus as
%  an algebraic loop, and its initial condition keeps the supervisor from
%  believing the bus is dead during the first samples.
intg = [SUP '/Vbus'];
raw  = [SUP '/Vbus raw'];
if getSimulinkBlockHandle(intg) <= 0 || getSimulinkBlockHandle(raw) <= 0
    ok = false; detail = 'filter blocks missing'; return
end
isInt = strcmp(get_param(intg,'BlockType'),'Integrator');
ic    = get_param(intg,'InitialCondition');
tag   = get_param(raw,'GotoTag');
gain  = get_param([SUP '/1//Tf'],'Gain');
ok = isInt && strcmp(ic,'mg.Vbus_nom') && strcmp(tag,'Vdc') && strcmp(gain,'1/mg.Tf_droop');
detail = sprintf('Integrator=%d, IC=%s, source tag=%s, gain=%s', isInt, ic, tag, gain);
end

function [ok,detail] = setpointSource(mdl)
%SETPOINTSOURCE  Both droop nodes take V0 from the supervisor.
NL  = char(10);
bat = [mdl '/Bidirectional DC//DC' NL ' Converter'];
lin = get_param(get_param(bat,'PortHandles').Inport(1),'Line');
batOK = false; batSrc = '<unconnected>';
if lin > 0
    sb = get_param(lin,'SrcBlockHandle');
    if sb > 0
        batSrc = get_param(sb,'Name');
        batOK  = strcmp(get_param(sb,'BlockType'),'From') && ...
                 strcmp(get_param(sb,'GotoTag'),'V0bat');
    end
end
gTag = get_param([mdl '/DROOP CONTROLLER/From'],'GotoTag');
ok = batOK && strcmp(gTag,'V0grid');
detail = sprintf('battery V0 <- %s, grid V0 <- tag %s', batSrc, gTag);
end

function [ok,detail] = limiterOK(sys,nodeName,satName,tagHi,tagLo)
%LIMITEROK  A Saturation Dynamic sits on the droop node output, fed by the
%  supervisor's limits, and the node feeds NOTHING else - so the reference the
%  inner loop sees, and the one that gets logged, are the limited one.
sat = [sys '/' satName];
if getSimulinkBlockHandle(sat) <= 0
    ok = false; detail = 'no limiter block'; return
end
% the library block's name carries a newline, so flatten before matching
ref = regexprep(get_param(sat,'ReferenceBlock'),'\s+',' ');
isSat = contains(ref,'Saturation Dynamic') || ...
        strcmp(get_param(sat,'BlockType'),'Saturate');
if ~isSat
    ok = false; detail = ['wrong block: ' ref]; return
end
hi = srcName(get_param(sat,'PortHandles').Inport(1));
u  = srcName(get_param(sat,'PortHandles').Inport(2));
lo = srcName(get_param(sat,'PortHandles').Inport(3));
nodeOut = get_param([sys '/' nodeName],'PortHandles').Outport(1);
lin = get_param(nodeOut,'Line');
nDst = 0;
if lin > 0
    d = get_param(lin,'DstBlockHandle'); nDst = sum(d > 0);
end
ok = strcmp(hi,['From ' tagHi]) && strcmp(u,nodeName) && ...
     strcmp(lo,['From ' tagLo]) && nDst == 1;
detail = sprintf('up<-%s, u<-%s, lo<-%s, node fan-out %d', hi, u, lo, nDst);
end

function n = srcName(portH)
lin = get_param(portH,'Line');
n = '<unconnected>';
if lin > 0
    b = get_param(lin,'SrcBlockHandle');
    if b > 0, n = get_param(b,'Name'); end
end
end

function [ok,detail] = relaysOK(SUP)
%RELAYSOK  Every supervisor threshold is a Relay - i.e. carries hysteresis -
%  its on-point is strictly above its off-point, and both are written in mg.
want = {'SOC above target','mg.SOC_target+mg.SOC_hyst/2','mg.SOC_target-mg.SOC_hyst/2'; ...
        'Bus emergency',   '-mg.Vbus_emerg',             '-mg.Vbus_emerg_off'; ...
        'SOC above floor', 'mg.SOC_min+mg.SOC_hyst',     'mg.SOC_min'; ...
        'SOC full',        'mg.SOC_max',                 'mg.SOC_max-mg.SOC_hyst'; ...
        'PV mode',         'mg.Vpv_ctrl_on',             'mg.Vpv_ctrl_off'};
mg = evalin('base','mg');  %#ok<NASGU>  referenced by the eval() below
bad = {};
for k = 1:size(want,1)
    b = [SUP '/' want{k,1}];
    if getSimulinkBlockHandle(b) <= 0
        bad{end+1} = [want{k,1} ' missing']; continue %#ok<AGROW>
    end
    on = get_param(b,'OnSwitchValue'); off = get_param(b,'OffSwitchValue');
    if ~strcmp(on,want{k,2}) || ~strcmp(off,want{k,3})
        bad{end+1} = sprintf('%s = %s/%s', want{k,1}, on, off); continue %#ok<AGROW>
    end
    if ~(eval(on) > eval(off))
        bad{end+1} = sprintf('%s has no hysteresis', want{k,1}); %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok, sprintf('%d hysteretic thresholds', size(want,1)), strjoin(bad,'; '));
end

function [ok,detail] = pvModeOK(mdl)
%PVMODEOK  The MPPT / voltage-control selector is the supervisor's signal, and
%  the manual dashboard override is gone.
pm  = [mdl '/PV + Boost/PV Control/PV Mode'];
sel = [pm '/PV Mode'];
isFrom = getSimulinkBlockHandle(sel) > 0 && strcmp(get_param(sel,'BlockType'),'From');
tag = ''; n = 0;
if isFrom
    tag = get_param(sel,'GotoTag');
    lin = get_param(get_param(sel,'PortHandles').Outport(1),'Line');
    if lin > 0
        dp = get_param(lin,'DstPortHandle');
        for k = 1:numel(dp)
            pn = get_param(dp(k),'PortNumber');
            if ischar(pn), pn = str2double(pn); end
            if pn == 2, n = n + 1; end
        end
    end
end
noSlider = isempty(find_system(mdl,'LookUnderMasks','all','FindAll','on', ...
                               'Type','Block','Name','Slider Switch'));
ok = isFrom && strcmp(tag,'pvMode') && n == 2 && noSlider;
detail = sprintf('From tag=%s, selector ports driven=%d, manual slider removed=%d', ...
                 tag, n, noSlider);
end

function [ok,detail] = breakerOK(mdl)
%BREAKEROK  A real three-phase breaker, initially closed, in the AC path
%  between the source and the transformer.
brk = [mdl '/PCC + Grid/Grid Breaker'];
if getSimulinkBlockHandle(brk) <= 0
    ok = false; detail = 'no Grid Breaker'; return
end
st  = get_param(brk,'InitialState');
ph3 = strcmp(get_param(brk,'SwitchA'),'on') && strcmp(get_param(brk,'SwitchB'),'on') && ...
      strcmp(get_param(brk,'SwitchC'),'on');
tms = get_param(brk,'SwitchTimes');
ext = get_param(brk,'External');
src = [mdl '/PCC + Grid/Three-Phase Source'];
sp  = get_param(src,'PortHandles').RConn;
bl  = get_param(brk,'PortHandles').LConn;
inline = true;
for k = 1:min(numel(sp),numel(bl))
    l1 = get_param(sp(k),'Line'); l2 = get_param(bl(k),'Line');
    inline = inline && l1 > 0 && l1 == l2;
end
% The breaker was later given a second switching time so it can RECLOSE, so the
% test is that mg.t_island is still what opens it, not that it is the only
% event.  Check 5.5 owns the full open/close cycle.
ok = strcmp(st,'closed') && ph3 && contains(tms,'mg.t_island') && ...
     strcmp(ext,'off') && inline;
detail = sprintf('%s, 3-phase=%d, times=%s, external=%s, in the source path=%d', ...
                 st, ph3, tms, ext, inline);
end

function [ok,detail] = islandTimeOK(mdl,SUP)
%ISLANDTIMEOK  The plant and the control cannot disagree about the island.
brk = get_param([mdl '/PCC + Grid/Grid Breaker'],'SwitchTimes');
stp = get_param([SUP '/Island'],'Time');
bef = get_param([SUP '/Island'],'Before');
aft = get_param([SUP '/Island'],'After');
% as above: the breaker's switching times are now a list, and what this check
% is really asserting is that the plant and the control cannot disagree about
% when the island STARTS
ok = contains(brk,'mg.t_island') && strcmp(stp,'mg.t_island') && ...
     strcmp(bef,'0') && strcmp(aft,'1');
detail = sprintf('breaker=%s, step=%s (%s -> %s)', brk, stp, bef, aft);
end

function [ok,detail] = symbolicSupervisor(SUP)
%SYMBOLICSUPERVISOR  Nothing in the supervisor is a magic number.  Every
%  threshold, gain and limit comes from mg, so the whole policy can be
%  retuned from microgridParams.m alone.  0 and 1 are structural, not tuning.
allowed = {'0','1','-1'};
b = find_system(SUP,'SearchDepth',1,'LookUnderMasks','all','Type','Block');
bad = {};
for k = 1:numel(b)
    if strcmp(b{k},SUP), continue; end
    nm = get_param(b{k},'Name');
    switch get_param(b{k},'BlockType')
        case 'Constant',   pn = {'Value'};
        case 'Gain',       pn = {'Gain'};
        case 'Saturate',   pn = {'UpperLimit','LowerLimit'};
        case 'Relay',      pn = {'OnSwitchValue','OffSwitchValue','OnOutputValue','OffOutputValue'};
        case 'Step',       pn = {'Time','Before','After'};
        case 'Integrator', pn = {'InitialCondition'};
        otherwise,         pn = {};
    end
    for j = 1:numel(pn)
        v = strtrim(get_param(b{k},pn{j}));
        if ismember(v,allowed) || contains(v,'mg.'), continue; end
        bad{end+1} = sprintf('%s.%s = %s', nm, pn{j}, v); %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok,'all thresholds reference mg', strjoin(bad,'; '));
end

function [ok,detail] = gateBlockOK(mdl)
%GATEBLOCKOK  All three grid-converter gate paths pass through a gridEnable
%  product.  Clamping the current limits stops the converter being commanded;
%  only gating stops it switching, and an AFE left modulating into an open
%  breaker drains its own DC link until the bus discharges into it.
G  = [mdl '/PCC + Grid'];
gc = [G '/Grid Converter Control'];
names = {'Gate block AFE','Gate block S_hi','Gate block S_lo'};
bad = {};
for k = 1:numel(names)
    b = [G '/' names{k}];
    if getSimulinkBlockHandle(b) <= 0
        bad{end+1} = [names{k} ' missing']; continue %#ok<AGROW>
    end
    ph = get_param(b,'PortHandles');
    s1 = srcName(ph.Inport(1));
    s2 = srcName(ph.Inport(2));
    if ~strcmp(s1,'Grid Converter Control') || ~strcmp(s2,'From gridEnable')
        bad{end+1} = sprintf('%s fed by %s / %s', names{k}, s1, s2); %#ok<AGROW>
    end
end
% and nothing may bypass them
nDirect = 0;
for j = 1:numel(get_param(gc,'PortHandles').Outport)
    lin = get_param(get_param(gc,'PortHandles').Outport(j),'Line');
    if lin > 0
        d = get_param(lin,'DstBlockHandle');
        for q = 1:numel(d)
            if d(q) > 0 && ~startsWith(get_param(d(q),'Name'),'Gate block')
                nDirect = nDirect + 1;
            end
        end
    end
end
if nDirect > 0
    bad{end+1} = sprintf('%d gate path(s) bypass the block', nDirect);
end
ok = isempty(bad);
detail = ternary(ok,'AFE, S_hi and S_lo all gated by gridEnable', strjoin(bad,'; '));
end

function [ok,detail] = batterySized(mdl)
%BATTERYSIZED  The pack must be able to deliver what its current limit
%  promises.  A limit the plant cannot honour is not a limit, it is a cliff:
%  when the terminal voltage sags the droop asks for more current to recover
%  the lost power, which sags it further, and at the limit the loop opens.
%  The test is the ISLAND duty - the only case where the battery carries the
%  park alone - expressed as a C-rate against the block's own nominal
%  discharge current.
bb = [mdl '/Battery/Battery'];
mg = evalin('base','mg');
chem   = get_param(bb,'BatType');
Inom   = str2double(get_param(bb,'Normal_OP'));      % block's nominal discharge current
Iisl   = mg.Pbus_rated/mg.Vbat_nom;                  % island duty
symbolic = strcmp(get_param(bb,'NomV'),'mg.Vbat_nom') && ...
           strcmp(get_param(bb,'NomQ'),'mg.Qbat_Ah');
ok = strcmp(chem,mg.BatChemistry) && symbolic && ...
     Iisl <= Inom && mg.Ibat_max >= Iisl && ...
     abs(mg.Dbat_nom - mg.Vbat_nom/mg.Vbus_nom) < 1e-9;
detail = sprintf('%s %g V/%g Ah, island %.0f A vs nominal %.0f A (%.2fC), limit %.0f A, D=%.3f', ...
                 chem, mg.Vbat_nom, mg.Qbat_Ah, Iisl, Inom, Iisl/mg.Qbat_Ah, mg.Ibat_max, mg.Dbat_nom);
end

%% ------------------------------------------- islanding, shedding, sessions

function [ok,detail] = droopFilterInit(mdl)
%DROOPFILTERINIT  The droop node's bus filter must have an initial condition.
%  A Transfer Fcn has none - it starts at zero, which told both droop nodes
%  the bus was dead for the first few milliseconds of every run and made them
%  saturate their current references into an already-healthy bus.
node = 'microgridLib/DC Droop Node';
if ~bdIsLoaded('microgridLib'), load_system('microgridLib'); end
f = [node '/Meas filter'];
isInt = getSimulinkBlockHandle(f) > 0 && strcmp(get_param(f,'BlockType'),'Integrator');
ic    = ''; if isInt, ic = get_param(f,'InitialCondition'); end
inst = find_system(mdl,'LookUnderMasks','all','FollowLinks','off', ...
                   'RegExp','on','ReferenceBlock','microgridLib/DC Droop Node');
bad = {};
for k = 1:numel(inst)
    v = '';
    try, v = get_param(inst{k},'Vinit'); catch, end
    if ~strcmp(v,'mg.Vbus_nom')
        bad{end+1} = sprintf('%s Vinit=%s', get_param(inst{k},'Name'), v); %#ok<AGROW>
    end
end
ok = isInt && strcmp(ic,'Vinit') && numel(inst) == 2 && isempty(bad);
detail = ternary(ok, sprintf('Integrator IC=%s, %d instances at mg.Vbus_nom', ic, numel(inst)), ...
                 sprintf('Integrator=%d IC=%s | %s', isInt, ic, strjoin(bad,'; ')));
end

function [ok,detail] = islandWindowOK(mdl)
%ISLANDWINDOWOK  island = step(t_island) - step(t_reconnect), and everything
%  that means "islanded" reads the window rather than the raw opening step.
sup = [mdl '/Supervisor'];
w   = [sup '/Island window'];
if getSimulinkBlockHandle(w) <= 0
    ok = false; detail = 'no Island window block'; return
end
signs = get_param(w,'Inputs');
s1 = srcName(get_param(w,'PortHandles').Inport(1));
s2 = srcName(get_param(w,'PortHandles').Inport(2));
t1 = get_param([sup '/Island'],'Time');
t2 = get_param([sup '/Reclose'],'Time');
% who consumes the window
want = {'Sel V0bat','Any allows','Goto island','log island'};
lin  = get_param(get_param(w,'PortHandles').Outport(1),'Line');
have = {};
if lin > 0
    d = get_param(lin,'DstBlockHandle');
    for k = 1:numel(d)
        if d(k) > 0, have{end+1} = get_param(d(k),'Name'); end %#ok<AGROW>
    end
end
missing = want(~ismember(want,have));
ok = strcmp(signs,'+-') && strcmp(s1,'Island') && strcmp(s2,'Reclose') && ...
     strcmp(t1,'mg.t_island') && strcmp(t2,'mg.t_reconnect') && isempty(missing);
detail = ternary(ok, sprintf('%s - %s, %d consumer(s)', t1, t2, numel(have)), ...
                 sprintf('signs=%s src=%s/%s times=%s/%s missing consumers: %s', ...
                         signs, s1, s2, t1, t2, strjoin(missing,',')));
end

function [ok,detail] = gridEnableOK(mdl)
%GRIDENABLEOK  The converter must come back LATER than the breaker.  Between
%  the reclose and the release the breaker is closed but the AFE is still
%  gated off and still in reset - that gap is the resynchronisation.
sup = [mdl '/Supervisor'];
ge  = [sup '/Grid enable'];
rel = [sup '/Release'];
if getSimulinkBlockHandle(rel) <= 0
    ok = false; detail = 'no Release step'; return
end
signs = get_param(ge,'Inputs');
srcs  = arrayfun(@(p) string(srcName(p)), get_param(ge,'PortHandles').Inport);
tRel  = get_param(rel,'Time');
mg    = evalin('base','mg');
ok = strcmp(signs,'+-+') && any(srcs == "Island") && any(srcs == "Release") && ...
     strcmp(tRel,'mg.t_reconnect+mg.t_resync') && mg.t_resync > 0;
detail = sprintf('gridEnable = %s of [%s], release at %s (t_resync = %g s)', ...
                 signs, strjoin(cellstr(srcs)',', '), tRel, mg.t_resync);
end

function [ok,detail] = breakerCycleOK(mdl)
brk = get_param([mdl '/PCC + Grid/Grid Breaker'],'SwitchTimes');
mg  = evalin('base','mg');
ok = strcmp(brk,'[mg.t_island mg.t_reconnect]') && mg.t_reconnect > mg.t_island;
detail = sprintf('SwitchTimes = %s  (%g s open, %g s closed)', brk, mg.t_island, mg.t_reconnect);
end

function [ok,detail] = afeResetOK(mdl)
%AFERESETOK  A loop that spent the island winding up against a dead grid must
%  not be handed back a live one.  'level' reset holds each integrator at its
%  initial condition for as long as afeReset is high.
GC = [mdl '/PCC + Grid/Grid Converter Control'];
bad = {};
for nm = {'PI Vlink','PI id','PI iq'}
    b = [GC '/' nm{1}];
    if ~strcmp(get_param(b,'ExternalReset'),'level')
        bad{end+1} = sprintf('%s reset=%s', nm{1}, get_param(b,'ExternalReset')); continue %#ok<AGROW>
    end
    ph = get_param(b,'PortHandles');
    if strcmp(srcName(ph.Inport(end)),'From afeReset'), continue; end
    bad{end+1} = sprintf('%s reset port fed by %s', nm{1}, srcName(ph.Inport(end))); %#ok<AGROW>
end
ok = isempty(bad);
detail = ternary(ok,'PI Vlink, PI id and PI iq all level-reset by afeReset', strjoin(bad,'; '));
end

function [ok,detail] = shedRelaysOK(mdl)
%SHEDRELAYSOK  Four hysteretic stages that shed BELOW the droop band and
%  restore INSIDE it - so nothing can shed on a load step or on the islanding
%  transient, and a restored bay cannot immediately trip the next stage.
sup = [mdl '/Supervisor'];
mg  = evalin('base','mg');
bad = {};
for k = 1:4
    b = [sup '/' sprintf('Shed %d',k)];
    if getSimulinkBlockHandle(b) <= 0
        bad{end+1} = sprintf('Shed %d missing',k); continue %#ok<AGROW>
    end
    on  = get_param(b,'OnSwitchValue');
    off = get_param(b,'OffSwitchValue');
    if ~strcmp(on,sprintf('-mg.Vshed(%d)',5-k)) || ~strcmp(off,sprintf('-mg.Vshed_rst(%d)',5-k))
        bad{end+1} = sprintf('Shed %d = %s/%s',k,on,off); continue %#ok<AGROW>
    end
    if ~strcmp(srcName(get_param(b,'PortHandles').Inport(1)),'Shed input')
        bad{end+1} = sprintf('Shed %d not watching the blended bus',k); %#ok<AGROW>
    end
end
% and the thresholds themselves have to make sense
if any(mg.Vshed >= mg.Vbus_min)
    bad{end+1} = 'a shed threshold sits inside the droop band';
end
if any(mg.Vshed_rst <= mg.Vshed)
    bad{end+1} = 'a restore threshold is not above its shed threshold';
end
% the point of the threshold rework: restore is referenced to NOMINAL,
% so a bay only comes back when the bus is genuinely healthy again, not as
% soon as the collapse stops
if any(mg.Vshed_rst < mg.Vbus_min)
    bad{end+1} = 'a restore threshold sits below the band floor';
end
if any(diff(mg.Vshed) >= 0)
    bad{end+1} = 'shed thresholds are not strictly staged';
end
ok = isempty(bad);
detail = ternary(ok, sprintf('shed at %s V, restore at %s V, band floor %g V', ...
                             mat2str(mg.Vshed), mat2str(mg.Vshed_rst), mg.Vbus_min), ...
                 strjoin(bad,'; '));
end

function [ok,detail] = shedSwitchesOK(mdl)
%SHEDSWITCHESOK  Each bay's resistance passes through a switch that can
%  command an open circuit.  The loads are Variable Resistors, so this is all
%  that "disconnecting a bay" needs - no breaker, no extra state.
bays = {'DC Load','shed1'; 'DC Load1','shed2'; 'DC Load2','shed3'; 'DC Load3','shed4'};
bad = {};
for k = 1:size(bays,1)
    sw = [mdl '/Shed ' bays{k,1}];
    if getSimulinkBlockHandle(sw) <= 0
        bad{end+1} = [bays{k,1} ' not switched']; continue %#ok<AGROW>
    end
    ph = get_param(sw,'PortHandles');
    if ~strcmp(srcName(ph.Inport(1)),['Open ' bays{k,1}]) || ...
       ~strcmp(srcName(ph.Inport(2)),['From ' bays{k,2}])
        bad{end+1} = sprintf('%s fed by %s / %s', bays{k,1}, ...
                             srcName(ph.Inport(1)), srcName(ph.Inport(2))); continue %#ok<AGROW>
    end
    if ~strcmp(get_param([mdl '/Open ' bays{k,1}],'Value'),'mg.Rload_open')
        bad{end+1} = [bays{k,1} ' open value not mg.Rload_open']; %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok,'4 bays, each switchable to mg.Rload_open', strjoin(bad,'; '));
end

function [ok,detail] = evProfilesWired(mdl)
NL = char(10);
names = {['From' NL 'Workspace'], ['From' NL 'Workspace1'], ...
         ['From' NL 'Workspace2'], ['From' NL 'Workspace3']};
bad = {};
for k = 1:numel(names)
    v = get_param([mdl '/' names{k}],'VariableName');
    if ~strcmp(v,sprintf('mg.evLoad{%d}',k))
        bad{end+1} = sprintf('bay %d reads %s', k, v); %#ok<AGROW>
    end
end
ok = isempty(bad);
detail = ternary(ok,'all four bays read mg.evLoad{k}', strjoin(bad,'; '));
end

function [ok,detail] = evProfilesOK()
%EVPROFILESOK  Every generated session must be a usable From Workspace table:
%  strictly increasing time, covering the whole horizon, and resistances that
%  stay between a bay at full power and an empty bay.
mg  = evalin('base','mg');
bad = {};
Rcc = mg.Vbus_nom^2/mg.Pload_peak;
for k = 1:numel(mg.evLoad)
    A = mg.evLoad{k};
    if any(diff(A(:,1)) <= 0)
        bad{end+1} = sprintf('bay %d time not strictly increasing',k); %#ok<AGROW>
    end
    if A(1,1) ~= 0 || abs(A(end,1) - mg.Tend) > 1e-9
        bad{end+1} = sprintf('bay %d spans %g..%g s, not 0..%g', k, A(1,1), A(end,1), mg.Tend); %#ok<AGROW>
    end
    if min(A(:,2)) < Rcc*0.99 || max(A(:,2)) > mg.Rload_idle*1.01
        bad{end+1} = sprintf('bay %d R %.1f..%.1f outside %.1f..%.0f', ...
                             k, min(A(:,2)), max(A(:,2)), Rcc, mg.Rload_idle); %#ok<AGROW>
    end
end
% the arrivals must still be STEPS - that is the part of the profile that
% matters for the control, and a generator is an easy way to lose them
steps = 0;
for k = 1:numel(mg.evLoad)
    A = mg.evLoad{k};
    dt = diff(A(:,1));
    steps = steps + sum(dt < 1e-5 & abs(diff(A(:,2))) > 1);
end
if steps < numel(mg.evLoad)
    bad{end+1} = sprintf('only %d sharp transition(s) across %d bays', steps, numel(mg.evLoad));
end
ok = isempty(bad);
detail = ternary(ok, sprintf('%d bays, %d sharp arrivals/departures, %.0f..%.0f ohm', ...
                             numel(mg.evLoad), steps, Rcc, mg.Rload_idle), strjoin(bad,'; '));
end

function [ok,detail] = shedRestoreLagOK(mdl)
%SHEDRESTORELAGOK  Voltage hysteresis alone limit-cycles: with the battery at
%  its current limit the droop loop is open, so freeing one bay pushes the bus
%  through the restore threshold in tens of milliseconds and the bay comes
%  straight back.  The two directions must therefore be decided on two
%  different signals - fast to shed, slow to restore - which the relays see as
%  max(-Vbus, -Vslow).
sup = [mdl '/Supervisor'];
si  = [sup '/Shed input'];
if getSimulinkBlockHandle(si) <= 0
    ok = false; detail = 'no Shed input blend'; return
end
fn = get_param(si,'Function');
s1 = srcName(get_param(si,'PortHandles').Inport(1));
s2 = srcName(get_param(si,'PortHandles').Inport(2));
slow = [sup '/Vbus slow'];
isInt = getSimulinkBlockHandle(slow) > 0 && strcmp(get_param(slow,'BlockType'),'Integrator');
ic   = ''; if isInt, ic = get_param(slow,'InitialCondition'); end
gain = ''; 
if getSimulinkBlockHandle([sup '/1//Tf reshed']) > 0
    gain = get_param([sup '/1//Tf reshed'],'Gain');
end
mg = evalin('base','mg');
ok = strcmp(fn,'max') && strcmp(s1,'neg Vbus') && strcmp(s2,'neg Vslow') && ...
     isInt && strcmp(ic,'mg.Vbus_nom') && strcmp(gain,'1/mg.Tf_reshed') && ...
     mg.Tf_reshed > mg.Tf_droop*10;
detail = sprintf('%s(%s, %s), slow lag %g s (droop filter %g s)', fn, s1, s2, ...
                 mg.Tf_reshed, mg.Tf_droop);
end

%% ======================================================================
%  the signals a completed simulation produced
%% ======================================================================
function nfail = resultChecks()
%CHECKREGRESSIONRUN  Check the logged signals of the last simulation.
%
% Run this straight after simulating microgrid.  It reads the
% To Workspace variables from the base workspace and tests them against the
% acceptance criteria of the completed phases.
%
% Called automatically by  runRegression('sim',true).
%
% Note.  The run is no longer one operating mode.  The breaker opens
% at mg.t_island, so the same recording contains a grid-connected microgrid
% and an islanded one, and most criteria only make sense inside one of them:
% "the AFE holds its DC link" is meaningless once the AFE has no source.
% Every check below therefore states which window it judges.

mg  = evalin('base','mg');
Ts  = 5e-6;

fprintf('\n--- SIMULATION CHECKS -------------------------------------------\n');
pass = 0; fail = 0;

Vdc = getvar('Vdc');
if isempty(Vdc)
    fprintf('  no logged data found - run a simulation first\n');
    nfail = 1; return
end

t    = (0:numel(Vdc)-1)'*Ts;
Tend = t(end);

% Not every 'Array' log runs at the bus voltage's rate - the battery model in
% particular logs SOC on its own solver steps - so each one gets its own time
% base spanning the run rather than being indexed against an assumed period.
tb = @(x) linspace(0, Tend, numel(x))';

% Start-up skip.  This was 20 ms for four phases, to hide an overshoot to
% ~819 V caused by the droop nodes' measurement filter starting at zero volts
% (the fix was to the filter, not the check).  With the filter initialised at
% the nominal bus there is nothing left to hide but two milliseconds of solver
% settling, so the window is now 2 ms and the rest of the run - including the
% start-up - is judged by every check below.
n0 = min(round(0.002/Ts), numel(Vdc));
Vs = Vdc(n0:end);

% The four load steps land between 0.20 s and 0.55 s.  A run that stops
% inside that window ends mid-transient, so the end-of-run value means
% nothing; only the last-load-step-and-after horizon is judged on it.
Tsettled = 0.70;

% ---- operating-mode windows -------------------------------------------
tIsl    = mg.t_island;
tRec    = mg.t_reconnect;
tRel    = tRec + mg.t_resync;
islands = tIsl < Tend;                     % does this run actually island?
recons  = islands && tRel < Tend;          % ...and come back?
tEndIsl = min([tRec, Tend]);
GRID    = t >= 0.05 & t <= min(tIsl,Tend) - 0.02;      % settled, grid connected
if islands
    ISLE = t >= tIsl + 0.05 & t <= tEndIsl - 0.005;    % settled, islanded
    TRAN = t >= tIsl        & t <= min(tIsl+0.10,Tend);% the opening transient
else
    ISLE = false(size(t));
    TRAN = false(size(t));
end
if recons
    RESYNC = t >= tRec  & t <  tRel;                   % breaker in, gates out
    BACK   = t >= tRel + 0.03 & t <= Tend;             % settled, reconnected
    RTRAN  = t >= tRel  & t <= min(tRel+0.05,Tend);    % the release transient
else
    RESYNC = false(size(t)); BACK = false(size(t)); RTRAN = false(size(t));
end

%% ---- bus, all phases ---------------------------------------------------
[pass,fail] = tally(pass,fail, 'DC bus stays inside 650 V .. drain threshold', ...
    min(Vs) > 650 && max(Vs) < mg.Vdrain_on, sprintf('%.0f .. %.0f V', min(Vs), max(Vs)));

[pass,fail] = tally(pass,fail, 'DC bus median sits at the nominal 800 V', ...
    abs(median(Vs) - mg.Vbus_nom) < 20, sprintf('median %.1f V', median(Vs)));

if Tend >= Tsettled
    [pass,fail] = tally(pass,fail, 'DC bus settled at nominal by end of run', ...
        abs(Vdc(end) - mg.Vbus_nom) < 20, sprintf('final %.1f V', Vdc(end)));
else
    skipped('DC bus settled at nominal by end of run', ...
        sprintf('run ends at %.2f s, inside the load-step window (needs >= %.2f s)', Tend, Tsettled));
end

[pass,fail] = tally(pass,fail, 'Dump resistor never tripped', ...
    max(Vs) < mg.Vdrain_on, sprintf('bus peak %.0f V vs trip %.0f V', max(Vs), mg.Vdrain_on));

[pass,fail] = tally(pass,fail, 'No NaN / Inf on the bus voltage', ...
    all(isfinite(Vdc)), sprintf('%d samples', numel(Vdc)));

%% ---- AFE DC link  (grid-connected window only) -------------------------
Vlink = getvar('Vlink');
if ~isempty(Vlink)
    Vl = window(Vlink, t, GRID);
    [pass,fail] = tally(pass,fail, 'AFE holds its DC link (grid-connected window)', ...
        abs(mean(Vl)-mg.Vlink_ref) < 15 && (max(Vl)-min(Vl)) < 60, ...
        sprintf('mean %.0f V, spread %.0f V', mean(Vl), max(Vl)-min(Vl)));
    if recons
        Vb2 = window(Vlink, t, BACK);
        [pass,fail] = tally(pass,fail, 'AFE recovers its DC link after reconnection', ...
            abs(mean(Vb2)-mg.Vlink_ref) < 40, ...
            sprintf('mean %.0f V (setpoint %.0f V)', mean(Vb2), mg.Vlink_ref));
    end
end

%% ---- battery ratings ---------------------------------------------------
I = getvar('ILbat');
if ~isempty(I)
    [pass,fail] = tally(pass,fail, 'Battery current within its rating', ...
        max(abs(I)) <= mg.Ibat_max*1.1, ...
        sprintf('|I|max %.0f A (limit %.0f A)', max(abs(I)), mg.Ibat_max));
end

Ig = getvar('Igrid');
if ~isempty(Ig)
    Ig = Ig(min(6,numel(Ig)):end);           % drop the t=0 solver artifact
    [pass,fail] = tally(pass,fail, 'Grid current bounded', ...
        max(abs(Ig)) < mg.Igrid_max*2, ...
        sprintf('|I|max %.0f A (rating %.0f A)', max(abs(Ig)), mg.Igrid_max));
end

S = getvar('SOC');
if ~isempty(S)
    [pass,fail] = tally(pass,fail, 'SOC finite and within 0-100 %', ...
        all(isfinite(S)) && all(S>=0 & S<=100), sprintf('%.3f .. %.3f %%', min(S), max(S)));
end

%% ---- battery converter ----------------------------------------
Iref = getvar('Ibat_ref');
if ~isempty(I) && ~isempty(Iref) && numel(I) == numel(Iref)
    e = I(n0:end) - Iref(n0:end);
    [pass,fail] = tally(pass,fail, 'Battery current tracks its reference', ...
        rms(e) < max(20, 0.10*max(abs(Iref))), ...
        sprintf('rms error %.1f A on a %.0f A span', rms(e), max(abs(Iref))));
end

S1 = getvar('S1'); S2 = getvar('S2');
if ~isempty(S1) && ~isempty(S2)
    d1 = mean(S1); d2 = mean(S2);
    [pass,fail] = tally(pass,fail, 'Battery half-bridge switches complementarily', ...
        abs(d1 + d2 - 1) < 0.02, sprintf('duties %.3f + %.3f = %.3f', d1, d2, d1+d2));
end

Db = getvar('D_bat');
if ~isempty(Db)
    % skip the same start-up the other checks skip: at t = 0 the SPS voltage
    % measurements read ~0, so the Vbat/Vbus feed-forward is briefly
    % meaningless and the duty sits on its floor for a few samples
    k0 = max(1, min(round(0.05*numel(Db)/Tend), numel(Db)));
    Ds = Db(k0:end);
    [pass,fail] = tally(pass,fail, 'Battery duty stays around its nominal Vbat/Vbus', ...
        abs(median(Ds) - mg.Dbat_nom) < 0.10 && min(Ds) > mg.Dbat_min && max(Ds) < mg.Dbat_max, ...
        sprintf('median %.3f vs nominal %.3f, range %.3f..%.3f', median(Ds), mg.Dbat_nom, min(Ds), max(Ds)));
end

%% ---- droop layer ---------------------------------------------
[pass,fail] = tally(pass,fail, 'Bus stays inside the droop band', ...
    min(Vs) > mg.Vbus_min && max(Vs) < mg.Vbus_max, ...
    sprintf('%.0f .. %.0f V in a %.0f - %.0f V band', min(Vs), max(Vs), mg.Vbus_min, mg.Vbus_max));

Igr = getvar('Igrid_ref');
if ~isempty(Igr)
    [pass,fail] = tally(pass,fail, 'Grid droop node produces a bounded reference', ...
        all(Igr >= mg.Igrid_min-1) && all(Igr <= mg.Igrid_max+1), ...
        sprintf('%.0f .. %.0f A within %.0f .. %.0f', min(Igr), max(Igr), mg.Igrid_min, mg.Igrid_max));
end

% End-to-end droop law.  This replaces the earlier fixed-set-point version:
% the set-point is no longer the constant mg.V0_bat, it is whatever the
% supervisor published, and the answer is then clipped by the policy limits.
% Predicting the reference from the LOGGED set-point and limits and comparing
% it with the reference the converter actually received tests the droop node,
% the limiter and the supervisor in one shot.
[tv,V0b]  = getsig('V0bat', Tend);
[~ ,Ihi]  = getsig('Ibat_hi', Tend);
[~ ,Ilo]  = getsig('Ibat_lo', Tend);
if ~isempty(V0b) && ~isempty(Iref)
    V0i  = interp1(tv, V0b, t, 'previous', 'extrap');
    Hi   = interp1(tv, Ihi, t, 'previous', 'extrap');
    Lo   = interp1(tv, Ilo, t, 'previous', 'extrap');
    pred = min(max((V0i - Vdc)/mg.Rdroop_bat, Lo), Hi);
    sel  = (GRID | ISLE) & isfinite(pred);
    if numel(Iref) ~= numel(t)
        Iref_t = interp1(tb(Iref), Iref, t, 'previous', 'extrap');
    else
        Iref_t = Iref;
    end
    res  = Iref_t(sel) - pred(sel);
    [pass,fail] = tally(pass,fail, 'Battery reference follows sat(droop law, policy limits)', ...
        rms(res) < 30, sprintf('rms %.1f A over %d settled samples', rms(res), sum(sel)));
end

%% ---- supervisor ----------------------------------------------
[ti,isl] = getsig('island', Tend);
if isempty(ti)
    skipped('Supervisor checks', ...
        'no island signal for this run - see the warning above, then re-run the model');
else
    % Islanding later became a WINDOW, so a run that also reconnects has two
    % transitions and is judged by 'Island opens and closes on schedule'
    % below.  This check now owns only the one-way case.
    if islands && ~recons
        k = find(diff(isl > 0.5) ~= 0);
        [pass,fail] = tally(pass,fail, 'Island flag rises once, at mg.t_island', ...
            numel(k) == 1 && abs(ti(k(1)+1) - tIsl) < 1e-3, ...
            sprintf('%d transition(s), first at %.4f s (expected %.4f)', ...
                    numel(k), ti(min(k(1)+1,numel(ti))), tIsl));
    elseif ~islands
        skipped('Island flag rises once, at mg.t_island', ...
            sprintf('run ends at %.2f s, before mg.t_island = %.2f s', Tend, tIsl));
    else
        skipped('Island flag rises once, at mg.t_island', ...
            'this run reconnects - see the island-window check');
    end

    % --- set-point bias -------------------------------------------------
    if ~isempty(S) && ~isempty(V0b)
        Si   = interp1(tb(S), S, tv, 'previous', 'extrap');
        want = min(max(mg.Vbus_nom - mg.k_soc*(mg.SOC_target - Si), mg.V0bat_min), mg.V0bat_max);
        want(isl > 0.5) = mg.Vbus_nom;          % islanded: bias removed
        [pass,fail] = tally(pass,fail, 'V0bat follows the clamped SOC bias', ...
            max(abs(V0b - want)) < 0.5, ...
            sprintf('max deviation %.3f V, V0bat %.1f .. %.1f V', ...
                    max(abs(V0b - want)), min(V0b), max(V0b)));
    end

    % --- grid-connected policy ------------------------------------------
    gsel = ti <= min(tIsl,Tend) - 0.02 & ti >= 0.05;
    if any(gsel) && ~isempty(S)
        Si = interp1(tb(S), S, ti, 'previous', 'extrap');
        below = gsel & Si < mg.SOC_target - mg.SOC_hyst;
        if any(below)
            [pass,fail] = tally(pass,fail, 'Below target SOC the battery may not discharge', ...
                all(Ihi(below) == 0), ...
                sprintf('Ibat_hi max %.1f A over %d samples below target SOC', ...
                        max(Ihi(below)), sum(below)));
            % ...and the deficit therefore has to come from the grid
            if ~isempty(Igr)
                tg = tb(Igr);
                gm = tg >= 0.05 & tg <= min(tIsl,Tend) - 0.02;
                [pass,fail] = tally(pass,fail, 'Grid covers the deficit while the battery is blocked', ...
                    mean(Igr(gm)) > 0, sprintf('mean grid reference %.1f A (import positive)', mean(Igr(gm))));
            end
        end
        [pass,fail] = tally(pass,fail, 'Grid limits open while grid-connected', ...
            all(Ihi(gsel) >= 0), sprintf('%d grid-connected samples', sum(gsel)));
    end

    % --- islanded policy -------------------------------------------------
    if islands
        % ...and end at the reclose, or the reconnected part of the run gets
        % judged against islanded expectations
        isel = ti >= tIsl + 0.05 & ti <= tEndIsl - 0.005;
        if any(isel)
            [pass,fail] = tally(pass,fail, 'Islanded: battery released to discharge', ...
                all(abs(Ihi(isel) - mg.Ibat_max) < 1e-6), ...
                sprintf('Ibat_hi %.0f A (rating %.0f A)', median(Ihi(isel)), mg.Ibat_max));
        end
        if ~isempty(Igr)
            tg = tb(Igr);
            im = tg >= tIsl + 0.05 & tg <= tEndIsl - 0.005;
            if any(im)
                [pass,fail] = tally(pass,fail, 'Islanded: grid reference clamped to zero', ...
                    max(abs(Igr(im))) < 1e-6, sprintf('|Igrid_ref|max %.3g A', max(abs(Igr(im)))));
            end
        end
        Vt = window(Vdc, t, TRAN);
        [pass,fail] = tally(pass,fail, 'Bus survives the islanding transient', ...
            min(Vt) > 650 && max(Vt) < mg.Vdrain_on, ...
            sprintf('%.0f .. %.0f V in the 100 ms after the breaker opens', min(Vt), max(Vt)));
        Vi = window(Vdc, t, ISLE);
        [pass,fail] = tally(pass,fail, 'Islanded: bus back inside the droop band', ...
            min(Vi) > mg.Vbus_min && max(Vi) < mg.Vbus_max, ...
            sprintf('%.0f .. %.0f V', min(Vi), max(Vi)));
        if ~isempty(I)
            Ii = window(I, t, ISLE);
            [pass,fail] = tally(pass,fail, 'Islanded: battery is the slack unit (net discharge)', ...
                mean(Ii) > 0, sprintf('mean battery current %+.0f A', mean(Ii)));
        end
    end

    % --- PV mode ----------------------------------------------------------
    [~,pvm] = getsig('pvMode', Tend);
    [~,en1] = getsig('pvEnMPPT', Tend);
    [~,en2] = getsig('pvEnVctrl', Tend);
    if ~isempty(pvm) && ~isempty(en1) && ~isempty(en2) && ...
       numel(pvm) == numel(en1) && numel(pvm) == numel(en2)
        [pass,fail] = tally(pass,fail, 'PV branches are exclusive and follow pvMode', ...
            all(en1 + en2 == 1) && all(en1 == (pvm > 0.5)), ...
            sprintf('MPPT active %.0f%% of the run, voltage control %.0f%%', ...
                    100*mean(en1), 100*mean(en2)));
    end
    if ~isempty(pvm)
        % the handover must not chatter: at most a couple of transitions
        nsw = sum(diff(pvm > 0.5) ~= 0);
        [pass,fail] = tally(pass,fail, 'PV mode handover does not chatter', ...
            nsw <= 4, sprintf('%d mode transition(s)', nsw));
    end
end


%% ---- soft-start, reconnection, shedding, charging sessions ----------

% Start-up.  The point of the filter fix is that the droop nodes no
% longer believe the bus is dead at t = 0, so neither reference should be
% anywhere near its limit in the first few milliseconds.
if ~isempty(Iref)
    early = t < 0.005;
    [pass,fail] = tally(pass,fail, 'Start-up: battery reference never saturates', ...
        max(abs(Iref(early))) < 0.5*mg.Ibat_max, ...
        sprintf('|Ibat_ref|max %.0f A in the first 5 ms (limit %.0f A)', ...
                max(abs(Iref(early))), mg.Ibat_max));
end
[pass,fail] = tally(pass,fail, 'Start-up: bus overshoot bounded', ...
    max(Vdc(t < 0.02)) < mg.Vbus_max, ...
    sprintf('peak %.1f V in the first 20 ms (band top %.0f V)', ...
            max(Vdc(t < 0.02)), mg.Vbus_max));

% Reconnection.
if recons && ~isempty(ti)
    k = find(diff(isl > 0.5) ~= 0);
    [pass,fail] = tally(pass,fail, 'Island opens and closes on schedule', ...
        numel(k) == 2 && abs(ti(k(1)+1)-tIsl) < 1e-3 && abs(ti(k(2)+1)-tRec) < 1e-3, ...
        sprintf('%d transition(s) at %s s', numel(k), ...
                strjoin(arrayfun(@(q) sprintf('%.3f',ti(min(q+1,numel(ti)))), k, 'uni',0), ', ')));

    if ~isempty(Igr)
        tgr = tb(Igr);
        rs  = tgr >= tRec & tgr < tRel - 1e-3;
        if any(rs)
            [pass,fail] = tally(pass,fail, 'Resync window: converter still stood down', ...
                max(abs(Igr(rs))) < 1e-6, ...
                sprintf('|Igrid_ref|max %.3g A between the reclose and the release', ...
                        max(abs(Igr(rs)))));
        end
        bk = tgr >= tRel + 0.03;
        if any(bk)
            [pass,fail] = tally(pass,fail, 'Reconnected: the grid carries load again', ...
                mean(Igr(bk)) > 1, sprintf('mean grid reference %+.0f A', mean(Igr(bk))));
        end
    end

    Vr = window(Vdc, t, RTRAN);
    [pass,fail] = tally(pass,fail, 'Bus survives the gate release', ...
        min(Vr) > mg.Vbus_min && max(Vr) < mg.Vbus_max, ...
        sprintf('%.0f .. %.0f V in the 50 ms after the gates come back', min(Vr), max(Vr)));

    Vb3 = window(Vdc, t, BACK);
    [pass,fail] = tally(pass,fail, 'Reconnected: bus back inside the droop band', ...
        min(Vb3) > mg.Vbus_min && max(Vb3) < mg.Vbus_max, ...
        sprintf('%.0f .. %.0f V', min(Vb3), max(Vb3)));

    if ~isempty(I)
        Ii2 = window(I, t, ISLE);
        Ib2 = window(I, t, BACK);
        [pass,fail] = tally(pass,fail, 'Battery hands the load back to the grid', ...
            mean(Ib2) < mean(Ii2), ...
            sprintf('battery %+.0f A islanded -> %+.0f A reconnected', mean(Ii2), mean(Ib2)));
    end
end

% Load shedding.  In a healthy run nothing should ever be shed - the whole
% point of the thresholds is that they sit below the operating band.
[~,shed] = getsig('shedLevel', Tend);
if ~isempty(shed)
    [pass,fail] = tally(pass,fail, 'Nothing shed during normal operation', ...
        all(shed == 0), sprintf('max stages shed %d', max(shed)));
end

fprintf('-----------------------------------------------------------------\n');
if fail == 0
    fprintf('  ALL %d SIMULATION CHECKS PASSED\n', pass);
else
    fprintf('  %d of %d SIMULATION CHECKS FAILED\n', fail, pass+fail);
end
fprintf('-----------------------------------------------------------------\n\n');
nfail = fail;
end

%% ======================================================================
function v = getvar(name)
%GETVAR  An 'Array' To Workspace variable, as a column.
if evalin('base', sprintf('exist(''%s'',''var'')', name))
    v = evalin('base', name);
    v = v(:);
else
    v = [];
end
end

function [tt,yy] = getsig(name, Tend)
%GETSIG  A 'Structure With Time' To Workspace variable, as (time, value).
%  The supervisor's signals run at their own rate, so they carry their own
%  time vector rather than being indexed against an assumed sample period.
%
%  Tend is the horizon of the run the PLANT logs came from, and it is checked,
%  not trusted.  The supervisor logs and the plant logs are separate variables
%  written by separate blocks, so one set can be replaced without the other -
%  the threshold sweep logs under exactly these names, so calling it (which
%  runRegression does) used to overwrite the supervisor half of a completed
%  simulation and leave the plant half alone.  Every check below would then
%  compare two different simulations and report confident, wrong failures.
%  A signal whose horizon does not match the run is treated as absent.
tt = []; yy = [];
if ~evalin('base', sprintf('exist(''%s'',''var'')', name)), return; end
s = evalin('base', name);
if isstruct(s) && isfield(s,'time') && isfield(s,'signals')
    tt = s.time(:);
    yy = s.signals.values(:);
elseif isnumeric(s)
    yy = s(:);
end
if nargin > 1 && ~isempty(tt) && abs(tt(end) - Tend) > max(0.01, 0.02*Tend)
    warning('checkRegressionRun:staleLog', ...
        ['%s spans 0 .. %.2f s but the run is %.2f s - it is from a different ' ...
         'simulation (most likely the threshold sweep, which logs under the ' ...
         'same names). Re-run the model, then call checkRegressionRun again.'], ...
        name, tt(end), Tend);
    tt = []; yy = [];
end
end

function y = window(x, t, mask)
%WINDOW  x sampled on its own uniform grid, restricted to a time window.
if numel(x) == numel(t)
    y = x(mask);
else
    tx = linspace(t(1), t(end), numel(x))';
    y  = x(interp1(t, double(mask), tx, 'nearest', 0) > 0.5);
end
if isempty(y), y = NaN; end
end

function [p,f] = tally(p,f,name,ok,detail)
if ok, s = 'PASS'; p = p+1; else, s = 'FAIL'; f = f+1; end
fprintf('  [%s]  %-52s %s\n', s, name, detail);
end

function skipped(name,detail)
fprintf('  [SKIP]  %-52s %s\n', name, detail);
end

function v = ternum(c,a,b)
if c, v = a; else, v = b; end
end

%% ======================================================================
%  supervisor threshold sweep
%% ======================================================================
function nfail = thresholdSweep()
%THRESHOLDSWEEP  Exercise every supervisor threshold directly.
%
%  WHY THIS EXISTS, AND WHY THE ACCELERATED PACK DID NOT WORK
%
%  The plan was to compress the battery's charge axis so the SOC
%  would cross its thresholds inside a runnable horizon.  It does not work,
%  and the scenario's own guard checks caught it: the Battery block fits the
%  Shepherd polarisation constant K from the rated capacity TOGETHER with the
%  nominal discharge current and the exponential zone, so a 1.5 Ah pack told
%  to behave like a 543 A one is not a fast battery, it is a broken one.
%  Measured: terminal voltage 400 V -> 0 V within 80 ms and a 12 kA charge
%  current.  Restoring R and the nominal current after the fact is not enough
%  because K is capacity-coupled too, and the block does not expose it.
%
%  So the SOC policy is tested where it actually lives - in the supervisor -
%  instead of through a plant that cannot be made to cooperate.  The
%  Supervisor subsystem is lifted into a harness, its two inputs (SOC and the
%  bus voltage) are driven directly, and every threshold and every hysteresis
%  loop is swept in both directions.  It runs in seconds rather than half an
%  hour, and it covers 0-100 % of SOC and the whole bus range, which no
%  plant run could reach.
%
%  What this DOESN'T prove is that the plant behaves sensibly at those SOCs -
%  that is what the microgridScenario sweeps ('soc90', 'pvcurtail') are for.
%  The two together are stronger than the accelerated run would have been.

mdl = 'microgrid';
h   = 'supervisorHarness';
if ~bdIsLoaded(mdl), load_system(mdl); end
mg  = evalin('base','mg');

%% ---- leave the base workspace exactly as we found it -------------------
%  This harness logs under the SAME variable names the model uses, and it also
%  has to override mg while it runs.  Everything it touches is stashed here and
%  put back on the way out, including on error.
%
%  Without this, calling runRegression (which calls this) after a completed
%  simulation silently replaced the supervisor half of that run's logs and left
%  the plant half alone - and checkRegressionRun then compared two different
%  simulations and reported confident, wrong failures.
touched = {'V0bat','Ibat_hi','Ibat_lo','island','pvMode','shedLevel', ...
           'socP','vdcP','mg'};
existed = false(1,numel(touched));
stash   = struct();
for q = 1:numel(touched)
    existed(q) = evalin('base', sprintf('exist(''%s'',''var'')', touched{q})) == 1;
    if existed(q), stash.(touched{q}) = evalin('base', touched{q}); end
end
restoreOnExit = onCleanup(@() restoreBase(touched, existed, stash)); %#ok<NASGU>

%% ---- drive profiles ----------------------------------------------------
%  0 - 9 s : SOC swept 0 -> 100, HELD at 100, then back to 0, at a nominal bus
%  9 - 13 s: bus swept 800 -> 700 -> 860 at a fixed mid SOC
%
%  The hold at 100 % matters: the full-pack relay trips AT SOC_max, and a ramp
%  that merely touches 100 for one instant is a knife edge that the logger can
%  miss.  A real pack approaches full asymptotically, so the profile holds.
%  The ramps are slow (25 %/s) and MaxStep is tight so an edge can be located
%  to a tenth of a percent - the point is to measure where each threshold
%  trips, not just that it does.
socP = [0 0; 4 100; 4.5 100; 8.5 0; 9 0; 9.001 50; 13 50];
vdcP = [0 mg.Vbus_nom; 9 mg.Vbus_nom; 11 700; 13 860];
assignin('base','socP',socP);
assignin('base','vdcP',vdcP);

%  the mode steps must stay out of the way - this harness tests thresholds,
%  not the islanding schedule
mgH = mg;  mgH.t_island = 100;  mgH.t_reconnect = 101;
assignin('base','mg',mgH);

%% ---- build the harness -------------------------------------------------
if bdIsLoaded(h), close_system(h,0); end
new_system(h); load_system(h); load_system('simulink');
add_block([mdl '/Supervisor'],[h '/Supervisor'],'Position',[300 100 460 200]);
add_block('simulink/Sources/From Workspace',[h '/socSrc'], ...
          'Position',[40 60 140 100],'VariableName','socP','SampleTime','0');
add_block('simulink/Sources/From Workspace',[h '/vdcSrc'], ...
          'Position',[40 160 140 200],'VariableName','vdcP','SampleTime','0');
add_block('simulink/Signal Routing/Goto',[h '/gSOC'], ...
          'Position',[190 70 250 90],'GotoTag','SOC','TagVisibility','global');
add_block('simulink/Signal Routing/Goto',[h '/gVdc'], ...
          'Position',[190 170 250 190],'GotoTag','Vdc','TagVisibility','global');
add_line(h,'socSrc/1','gSOC/1'); add_line(h,'vdcSrc/1','gVdc/1');

cs = getActiveConfigSet(h);
set_param(cs,'SolverType','Variable-step','Solver','ode45', ...
             'StopTime','13','MaxStep','2e-4','RelTol','1e-4');

%% ---- run ---------------------------------------------------------------
%  sim() hands its logs back in a SimulationOutput rather than writing them to
%  the base workspace the way an interactive run does, so they are unpacked
%  explicitly - otherwise the checks below quietly read whatever the previous
%  run left behind.
out = evalc_sim(h);
close_system(h,0);
logged = {'V0bat','Ibat_hi','Ibat_lo','island','pvMode','shedLevel'};
for q = 1:numel(logged)
    if isprop(out,logged{q}) || ismember(logged{q}, out.who)
        assignin('base', logged{q}, out.(logged{q}));
    else
        error('microgridCheck:missingLog', ...
              'the harness produced no %s - check the Supervisor copy', logged{q});
    end
end

%% ---- check -------------------------------------------------------------
fprintf('\n--- SUPERVISOR THRESHOLD SWEEP --------------------------------\n');
pass = 0; fail = 0;
%  every logger in the Supervisor shares a rate, but they are put on one
%  common time base explicitly rather than assumed to line up
[t,V0b] = sig('V0bat');
Ihi  = onto(t,'Ibat_hi');
Ilo  = onto(t,'Ibat_lo');
pvm  = onto(t,'pvMode');
shed = onto(t,'shedLevel');
soc  = interp1(socP(:,1),socP(:,2),t,'linear','extrap');
vdc  = interp1(vdcP(:,1),vdcP(:,2),t,'linear','extrap');

% ---- SOC sweep window --------------------------------------------------
w = t <= 9;
full = t >= 4.05 & t <= 4.45;      % the hold at a full pack
[pass,fail] = tally(pass,fail,'Discharge blocked below the SOC target', ...
    all(Ihi(w & soc < mg.SOC_target - mg.SOC_hyst) == 0), ...
    sprintf('Ibat_hi max %.0f A below %g %%', ...
            maxOr0(Ihi(w & soc < mg.SOC_target - mg.SOC_hyst)), mg.SOC_target));
[pass,fail] = tally(pass,fail,'Discharge released above the SOC target', ...
    all(abs(Ihi(w & soc > mg.SOC_target + mg.SOC_hyst) - mg.Ibat_max) < 1e-6), ...
    sprintf('Ibat_hi = %.0f A above %g %%', ...
            medianOr0(Ihi(w & soc > mg.SOC_target + mg.SOC_hyst)), mg.SOC_target));
[pass,fail] = tally(pass,fail,'Charging blocked at a full pack', ...
    all(Ilo(full) == 0), ...
    sprintf('Ibat_lo = %.0f A while held at %g %%', medianOr0(Ilo(full)), mg.SOC_max));
[pass,fail] = tally(pass,fail,'Charging allowed below full', ...
    all(abs(Ilo(w & soc < mg.SOC_max - mg.SOC_hyst - 1) + mg.Ibat_max) < 1e-6), ...
    sprintf('Ibat_lo = %.0f A below %g %%', ...
            medianOr0(Ilo(w & soc < mg.SOC_max - mg.SOC_hyst - 1)), mg.SOC_max));

wantV0 = min(max(mg.Vbus_nom - mg.k_soc*(mg.SOC_target - soc), mg.V0bat_min), mg.V0bat_max);
[pass,fail] = tally(pass,fail,'Set-point bias follows the clamped SOC law', ...
    max(abs(V0b(w) - wantV0(w))) < 0.5, ...
    sprintf('max deviation %.3f V over a %.1f .. %.1f V range', ...
            max(abs(V0b(w) - wantV0(w))), min(V0b(w)), max(V0b(w))));

% every threshold must flip exactly ONCE up and once down over the sweep
[pass,fail] = tally(pass,fail,'SOC thresholds do not chatter', ...
    nflip(Ihi(w)) == 2 && nflip(Ilo(w)) == 2, ...
    sprintf('Ibat_hi %d transition(s), Ibat_lo %d over a 0-100-0 %% sweep', ...
            nflip(Ihi(w)), nflip(Ilo(w))));

% and they must flip at the RIGHT place, with the stated hysteresis
[up,dn] = edges(t(w), soc(w), Ihi(w));
[pass,fail] = tally(pass,fail,'Discharge limit hysteresis is SOC_hyst wide', ...
    abs(up - (mg.SOC_target + mg.SOC_hyst/2)) < 0.5 && ...
    abs(dn - (mg.SOC_target - mg.SOC_hyst/2)) < 0.5, ...
    sprintf('opens at %.2f %%, closes at %.2f %% (expected %.1f / %.1f)', ...
            up, dn, mg.SOC_target + mg.SOC_hyst/2, mg.SOC_target - mg.SOC_hyst/2));

% ---- bus sweep window --------------------------------------------------
v = t > 9.05;
[pass,fail] = tally(pass,fail,'PV holds MPPT below the curtailment threshold', ...
    all(pvm(v & vdc < mg.Vpv_ctrl_off - 1) == 1), ...
    sprintf('pvMode = 1 below %g V', mg.Vpv_ctrl_off));
[pass,fail] = tally(pass,fail,'PV takes voltage control above the threshold', ...
    any(pvm(v & vdc > mg.Vpv_ctrl_on) == 0), ...
    sprintf('pvMode reaches 0 above %g V', mg.Vpv_ctrl_on));

for k = 1:4
    lo = mg.Vshed(k); hi = mg.Vshed_rst(k);
    onIt  = v & vdc < lo - 5;
    [pass,fail] = tally(pass,fail, sprintf('Shed stage %d fires below %g V',k,lo), ...
        all(shed(onIt) >= k), sprintf('min stages shed %d while the bus is under %g V', ...
                                      minOr0(shed(onIt)), lo));
end
[pass,fail] = tally(pass,fail,'Every bay restored once the bus is back at nominal', ...
    shed(end) == 0, sprintf('%d bay(s) still shed at 860 V', shed(end)));
[pass,fail] = tally(pass,fail,'Shedding is monotonic in bus voltage', ...
    nflip(shed(v)) <= 8, sprintf('%d stage change(s) over a full down-and-up sweep', nflip(shed(v))));

fprintf('---------------------------------------------------------------\n');
if fail == 0
    fprintf('  ALL %d THRESHOLD CHECKS PASSED\n', pass);
else
    fprintf('  %d of %d THRESHOLD CHECKS FAILED\n', fail, pass+fail);
end
fprintf('---------------------------------------------------------------\n\n');
nfail = fail;
end

% -------------------------------------------------------------------------
function restoreBase(names, existed, stash)
%RESTOREBASE  Put every base-workspace name this harness touched back the way
%  it was - or remove it again if it was not there to begin with.
for q = 1:numel(names)
    if existed(q)
        assignin('base', names{q}, stash.(names{q}));
    else
        evalin('base', sprintf('clear %s', names{q}));
    end
end
end

function out = evalc_sim(h)
evalc('out = sim(h);');
end

function [tt,yy] = sig(nm)
s = evalin('base', nm);
tt = s.time(:); yy = s.signals.values(:);
end

function y = onto(t, nm)
%ONTO  A logged signal resampled onto the master time base.
[tt,yy] = sig(nm);
y = interp1(tt, yy, t, 'previous', 'extrap');
end

function n = nflip(x),  n = sum(diff(x) ~= 0); end
function y = maxOr0(x), if isempty(x), y = 0; else, y = max(x); end, end
function y = minOr0(x), if isempty(x), y = 0; else, y = min(x); end, end
function y = medianOr0(x), if isempty(x), y = 0; else, y = median(x); end, end

function [up,dn] = edges(t, drive, y)
%EDGES  The drive value at the rising and falling edge of a binary signal.
k = find(diff(y > max(y)/2) ~= 0);
up = NaN; dn = NaN;
for q = 1:numel(k)
    if y(k(q)+1) > y(k(q)), up = drive(k(q)+1); else, dn = drive(k(q)+1); end
end
end

