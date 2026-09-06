function build_01_supervisor(mdl)
%PHASE4_BUILD_SUPERVISOR  Create the Phase 4 supervisor subsystem.
%
%  The supervisor NEVER touches a duty cycle.  It publishes eight signals
%  that the Phase 3 droop nodes and the PV controller consume:
%
%     V0bat    battery droop set-point, biased by the SOC error
%     Ibat_hi  battery DISCHARGE limit  (0 blocks discharging)
%     Ibat_lo  battery CHARGE limit     (0 blocks charging)
%     V0grid   grid droop set-point
%     Igrid_hi grid import limit        (0 while islanded)
%     Igrid_lo grid export limit        (0 while islanded)
%     pvMode   1 = MPPT , 0 = PV voltage control
%     island   0 = grid connected , 1 = islanded
%
%  Built entirely from ordinary Simulink blocks - no MATLAB Function, no
%  Stateflow - so the whole policy can be read straight off the diagram.
%  Idempotent: deletes and rebuilds the subsystem if it already exists.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
sup = [mdl '/Supervisor'];

if getSimulinkBlockHandle(sup) > 0, delete_block(sup); end
add_block('built-in/SubSystem', sup, 'Position', [60 900 220 990]);

A = @(lib,nm,pos,varargin) add_block(['simulink/' lib], [sup '/' nm], ...
                                     'Position', pos, varargin{:});
L = @(a,b) add_line(sup, a, b, 'autorouting', 'on');

%% ---- measurements ------------------------------------------------------
A('Signal Routing/From','SOC',       [ 30  40  90  60], 'GotoTag','SOC');
A('Signal Routing/From','Vbus raw',  [ 30 100  90 120], 'GotoTag','Vdc');

%  Bus-voltage measurement filter.  It is here for two reasons.
%  Physically: the supervisor decides MODES, and a mode must not flip on
%  switching ripple, so it looks at a filtered bus like every other node.
%  Structurally: the relays below are direct-feedthrough blocks sitting in a
%  path that runs Vbus -> mode -> duty -> plant -> Vbus.  Without a state in
%  that path Simulink sees an algebraic loop and refuses to compile.  The
%  integrator IS that state, and its initial condition is the nominal bus, so
%  the supervisor does not spend the first samples believing the bus is dead.
%       y' = (Vbus - y)/Tf_droop ,  y(0) = Vbus_nom
A('Math Operations/Sum','Vbus f err',[130 100 150 140], 'Inputs','+-');
A('Math Operations/Gain','1//Tf',    [180 102 230 138], 'Gain','1/mg.Tf_droop');
A('Continuous/Integrator','Vbus',    [260 100 300 140], ...
   'InitialCondition','mg.Vbus_nom');
L('Vbus raw/1','Vbus f err/1');
L('Vbus f err/1','1//Tf/1');
L('1//Tf/1','Vbus/1');
L('Vbus/1','Vbus f err/2');
A('Sources/Step',       'Island',    [ 30 160  90 190], ...
   'Time','mg.t_island','Before','0','After','1','SampleTime','0');
A('Signal Routing/Goto','Goto island',[150 160 230 180], ...
   'GotoTag','island','TagVisibility','global');
A('Sinks/To Workspace', 'log island',[150 200 230 230], ...
   'VariableName','island','SaveFormat','StructureWithTime','SampleTime','-1', ...
   'MaxDataPoints','inf','Decimation','20');

%% ---- battery droop set-point  V0bat -----------------------------------
%  V0bat = sat( Vbus_nom - k_soc*(SOC_target - SOC) , V0bat_min , V0bat_max )
%  Below target the battery sits on a LOWER droop line and therefore absorbs;
%  above target it sits higher and supplies.  Islanded the bias is dropped -
%  the battery is then the slack unit and must hold the nominal bus.
A('Sources/Constant','SOC target',[ 30 300  90 320], 'Value','mg.SOC_target');
A('Math Operations/Sum','SOC err',[150 300 170 340], 'Inputs','+-');
A('Math Operations/Gain','k_soc', [210 302 250 338], 'Gain','mg.k_soc');
A('Sources/Constant','Vbus nom',  [210 240 280 260], 'Value','mg.Vbus_nom');
A('Math Operations/Sum','V0bat raw',[320 250 340 290], 'Inputs','+-');
A('Discontinuities/Saturation','Sat V0bat',[380 250 420 290], ...
   'UpperLimit','mg.V0bat_max','LowerLimit','mg.V0bat_min');
A('Sources/Constant','Vbus nom island',[380 175 470 195], 'Value','mg.Vbus_nom');
A('Signal Routing/Switch','Sel V0bat',[510 175 540 295], ...
   'Criteria','u2 > Threshold','Threshold','0.5');
A('Signal Routing/Goto','Goto V0bat',[590 225 670 245], ...
   'GotoTag','V0bat','TagVisibility','global');
A('Sinks/To Workspace','log V0bat',[590 265 670 295], ...
   'VariableName','V0bat','SaveFormat','StructureWithTime','SampleTime','-1', ...
   'MaxDataPoints','inf','Decimation','20');

L('SOC target/1','SOC err/1');  L('SOC/1','SOC err/2');
L('SOC err/1','k_soc/1');
L('Vbus nom/1','V0bat raw/1');  L('k_soc/1','V0bat raw/2');
L('V0bat raw/1','Sat V0bat/1');
L('Vbus nom island/1','Sel V0bat/1');
L('Island/1','Sel V0bat/2');
L('Sat V0bat/1','Sel V0bat/3');
L('Sel V0bat/1','Goto V0bat/1');
L('Sel V0bat/1','log V0bat/1');
L('Island/1','Goto island/1');
L('Island/1','log island/1');

%% ---- battery DISCHARGE limit  Ibat_hi ---------------------------------
%  Discharging is allowed when ANY of
%     - we are islanded                       (battery is the only slack unit)
%     - SOC is above target                   (spec: above 80 % the battery,
%                                              not the grid, covers the deficit)
%     - the bus has collapsed below Vbus_emerg (holding the bus outranks SOC)
%  AND the SOC is above the hard floor SOC_min.  Every comparison is a Relay,
%  so each one carries its own hysteresis and cannot chatter on ripple.
A('Discontinuities/Relay','SOC above target',[150 400 220 450], ...
   'OnSwitchValue','mg.SOC_target+mg.SOC_hyst/2', ...
   'OffSwitchValue','mg.SOC_target-mg.SOC_hyst/2', ...
   'OnOutputValue','1','OffOutputValue','0');
A('Math Operations/Gain','neg Vbus',[ 60 470 100 510], 'Gain','-1');
A('Discontinuities/Relay','Bus emergency',[150 470 220 520], ...
   'OnSwitchValue','-mg.Vbus_emerg','OffSwitchValue','-mg.Vbus_emerg_off', ...
   'OnOutputValue','1','OffOutputValue','0');
A('Math Operations/Sum','Any allows',[270 400 290 500], 'Inputs','+++');
A('Discontinuities/Saturation','Sat allows',[330 430 370 470], ...
   'UpperLimit','1','LowerLimit','0');
A('Discontinuities/Relay','SOC above floor',[270 560 340 610], ...
   'OnSwitchValue','mg.SOC_min+mg.SOC_hyst','OffSwitchValue','mg.SOC_min', ...
   'OnOutputValue','1','OffOutputValue','0');
A('Math Operations/Product','Discharge enable',[420 440 450 570]);
A('Math Operations/Gain','Ibat hi',[500 480 560 520], 'Gain','mg.Ibat_max');
A('Signal Routing/Goto','Goto Ibat_hi',[610 490 690 510], ...
   'GotoTag','Ibat_hi','TagVisibility','global');
A('Sinks/To Workspace','log Ibat_hi',[610 530 690 560], ...
   'VariableName','Ibat_hi','SaveFormat','StructureWithTime','SampleTime','-1', ...
   'MaxDataPoints','inf','Decimation','20');

L('SOC/1','SOC above target/1');
L('Vbus/1','neg Vbus/1');
L('neg Vbus/1','Bus emergency/1');
L('Island/1','Any allows/1');
L('SOC above target/1','Any allows/2');
L('Bus emergency/1','Any allows/3');
L('Any allows/1','Sat allows/1');
L('SOC/1','SOC above floor/1');
L('Sat allows/1','Discharge enable/1');
L('SOC above floor/1','Discharge enable/2');
L('Discharge enable/1','Ibat hi/1');
L('Ibat hi/1','Goto Ibat_hi/1');
L('Ibat hi/1','log Ibat_hi/1');

%% ---- battery CHARGE limit  Ibat_lo ------------------------------------
%  Charging is always allowed until the pack is full.  There is deliberately
%  no SOC_target ceiling here: grid-connected the battery is TOPPED UP to the
%  target by the set-point bias, and islanded it must be able to take
%  everything the PV produces, right up to SOC_max.
A('Discontinuities/Relay','SOC full',[270 660 340 710], ...
   'OnSwitchValue','mg.SOC_max','OffSwitchValue','mg.SOC_max-mg.SOC_hyst', ...
   'OnOutputValue','0','OffOutputValue','1');
A('Math Operations/Gain','Ibat lo',[420 665 490 705], 'Gain','-mg.Ibat_max');
A('Signal Routing/Goto','Goto Ibat_lo',[610 675 690 695], ...
   'GotoTag','Ibat_lo','TagVisibility','global');
A('Sinks/To Workspace','log Ibat_lo',[610 715 690 745], ...
   'VariableName','Ibat_lo','SaveFormat','StructureWithTime','SampleTime','-1', ...
   'MaxDataPoints','inf','Decimation','20');

L('SOC/1','SOC full/1');
L('SOC full/1','Ibat lo/1');
L('Ibat lo/1','Goto Ibat_lo/1');
L('Ibat lo/1','log Ibat_lo/1');

%% ---- grid limits and set-point ----------------------------------------
%  Islanded the grid node is clamped to zero in BOTH directions.  Without
%  this the grid droop node keeps commanding current into a dead breaker and
%  its inner current loop winds up against a converter that cannot deliver.
A('Sources/Constant','one',[150 790 200 810], 'Value','1');
A('Math Operations/Sum','Grid enable',[270 790 290 830], 'Inputs','+-');
A('Math Operations/Gain','Igrid hi',[350 760 420 800], 'Gain','mg.Igrid_max');
A('Math Operations/Gain','Igrid lo',[350 830 420 870], 'Gain','mg.Igrid_min');
A('Signal Routing/Goto','Goto Igrid_hi',[610 770 690 790], ...
   'GotoTag','Igrid_hi','TagVisibility','global');
%  The same flag also GATES the grid converter.  Clamping its current limits
%  stops it being commanded; it does not stop it switching, and an AFE left
%  modulating into an open breaker drains its own DC link through the
%  transformer until the bus starts discharging into it.  See
%  build_06_converter_gate_block.m.
A('Signal Routing/Goto','Goto gridEnable',[610 700 690 720], ...
   'GotoTag','gridEnable','TagVisibility','global');
A('Signal Routing/Goto','Goto Igrid_lo',[610 840 690 860], ...
   'GotoTag','Igrid_lo','TagVisibility','global');
A('Sources/Constant','V0grid',[350 910 420 930], 'Value','mg.V0_grid');
A('Signal Routing/Goto','Goto V0grid',[610 910 690 930], ...
   'GotoTag','V0grid','TagVisibility','global');

L('one/1','Grid enable/1');
L('Island/1','Grid enable/2');
L('Grid enable/1','Igrid hi/1');
L('Grid enable/1','Igrid lo/1');
L('Grid enable/1','Goto gridEnable/1');
L('Igrid hi/1','Goto Igrid_hi/1');
L('Igrid lo/1','Goto Igrid_lo/1');
L('V0grid/1','Goto V0grid/1');

%% ---- PV mode handover --------------------------------------------------
%  Latching hysteresis on the BUS voltage.  Once the PV has taken over the
%  bus it holds it at Vpv_ctrl_ref = the relay's own on-point, so the relay
%  stays latched; it only releases when the bus actually falls to
%  Vpv_ctrl_off, i.e. when the PV can no longer hold it.  That is why the
%  PV voltage-control reference is a FIXED set-point and not a droop line:
%  a drooping reference would sink below the release point at high PV
%  current and the mode would limit-cycle.
A('Discontinuities/Relay','PV mode',[270 990 340 1040], ...
   'OnSwitchValue','mg.Vpv_ctrl_on','OffSwitchValue','mg.Vpv_ctrl_off', ...
   'OnOutputValue','0','OffOutputValue','1');
A('Signal Routing/Goto','Goto pvMode',[430 1005 510 1025], ...
   'GotoTag','pvMode','TagVisibility','global');
A('Sinks/To Workspace','log pvMode',[430 1045 510 1075], ...
   'VariableName','pvMode','SaveFormat','StructureWithTime','SampleTime','-1', ...
   'MaxDataPoints','inf','Decimation','20');

L('Vbus/1','PV mode/1');
L('PV mode/1','Goto pvMode/1');
L('PV mode/1','log pvMode/1');

fprintf('build_01_supervisor: %s built (%d blocks)\n', sup, ...
        numel(find_system(sup,'SearchDepth',1,'Type','Block')) - 1);
end
