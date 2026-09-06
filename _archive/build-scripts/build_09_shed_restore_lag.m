function build_09_shed_restore_lag(mdl)
%PHASE5_SHED_RESTORE_LAG  Make load shedding restore on a SUSTAINED recovery.
%
%  THE BUG.  The four shed relays watched the same bus voltage in both
%  directions, so a bay that had just been shed was restored the moment the
%  bus popped above the restore threshold - which, with the battery pinned at
%  its current limit, it always does, because the loop is open and the freed
%  power simply charges the bus capacitor.  Measured in the overload scenario:
%  shed at 754 V, restored 24 ms later at 780 V, twelve times in half a
%  second.  A 20 Hz limit cycle, and every cycle a 90 kW step on the bus.
%
%  THE FIX.  Decide the two directions on two different signals:
%
%      SHED     on the instantaneous bus  - a collapse must be caught at once
%      RESTORE  on a slowly filtered bus  - a recovery must be sustained
%
%  The relays see max(-Vbus, -Vslow), and because they trip on the NEGATED bus
%  the max picks whichever signal is more pessimistic in each direction: the
%  fast one while the bus is falling, the slow one while it is rising.  One
%  extra filter and one MinMax block for all four stages, and no timers, no
%  latches and no extra state per bay.
%
%  Idempotent.

if nargin < 1, mdl = 'microgrid'; end
load_system('simulink');
sup = [mdl '/Supervisor'];
if getSimulinkBlockHandle([sup '/Shed input']) > 0
    fprintf('build_09_shed_restore_lag: already installed\n'); return
end
A = @(lib,nm,pos,varargin) add_block(['simulink/' lib], [sup '/' nm], ...
                                     'Position', pos, varargin{:});

%  the slow bus, built the same way as every other filter in the supervisor so
%  it starts at the nominal bus instead of at zero
A('Math Operations/Sum','slow err',[ 60 1040  80 1080],'Inputs','+-');
A('Math Operations/Gain','1//Tf reshed',[110 1042 170 1078],'Gain','1/mg.Tf_reshed');
A('Continuous/Integrator','Vbus slow',[200 1040 240 1080], ...
   'InitialCondition','mg.Vbus_nom');
A('Math Operations/Gain','neg Vslow',[280 1042 330 1078],'Gain','-1');
A('Math Operations/MinMax','Shed input',[380 1040 410 1080], ...
   'Function','max','Inputs','2');

add_line(sup,'Vbus/1','slow err/1','autorouting','on');
add_line(sup,'slow err/1','1//Tf reshed/1','autorouting','on');
add_line(sup,'1//Tf reshed/1','Vbus slow/1','autorouting','on');
add_line(sup,'Vbus slow/1','slow err/2','autorouting','on');
add_line(sup,'Vbus slow/1','neg Vslow/1','autorouting','on');
add_line(sup,'neg Vbus/1','Shed input/1','autorouting','on');
add_line(sup,'neg Vslow/1','Shed input/2','autorouting','on');

%  move the four stages off the raw bus and onto the blend
for k = 1:4
    nm = sprintf('Shed %d', k);
    p  = get_param([sup '/' nm],'PortHandles').Inport(1);
    lin = get_param(p,'Line');
    if lin > 0, delete_line(lin); end
    add_line(sup, get_param([sup '/Shed input'],'PortHandles').Outport(1), p, ...
             'autorouting','on');
end

fprintf('build_09_shed_restore_lag: shedding now restores only on a sustained recovery\n');
end
